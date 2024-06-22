import Alamofire
import Combine
import Foundation
import SwiftData

let maxPinChatSequenceDesc = 140

@Observable
class OneSequenceViewModel: ObservableObject {
    var sequence: ChatSequence
    let chatService: ChatSyncService
    let settings: CSCSettingsService.SettingsProxy
    let chatSettingsService: CSCSettingsService
    let appSettings: AppSettings

    var promptInEdit: String = ""
    var submitting: Bool = false

    var responseInEdit: Message? = nil
    var receiving: Bool {
        /// This field does double duty to indicate whether we are currently receiving data.
        /// `nil` before first data, and then reset to `nil` once we're done receiving.
        get { responseInEdit != nil }
    }

    @ObservationIgnored var submittedAssistantResponseSeed: String? = nil
    @ObservationIgnored private var receivingStreamer: AnyCancellable? = nil
    var serverStatus: String? = nil

    private var stayAwake: StayAwake = StayAwake()
    var currentlyAwakeDuringInference: Bool {
        get { stayAwake.assertionIsActive }
    }

    // MARK: - Options and Configurations
    var showTextEntryView: Bool = true
    var showUiOptions: Bool = false
    var showInferenceOptions: Bool = false
    var showRetrievalOptions: Bool = false

    var continuationInferenceModel: FoundationModel? = nil
    var showAssistantResponseSeed: Bool = false
    var showSystemPromptOverride: Bool = false

    static func createBlank(chatService: ChatSyncService, appSettings: AppSettings, chatSettingsService: CSCSettingsService) -> OneSequenceViewModel {
        let sequence = ChatSequence(
            clientId: UUID(),
            serverId: nil,
            humanDesc: nil,
            userPinned: false,
            messages: [
                Message(role: "placeholder", content: "", createdAt: nil),
            ],
            inferenceModelId: nil)

        let settings = CSCSettingsService.SettingsProxy(
            defaults: chatSettingsService.defaults,
            override: OverrideCSUISettings(),
            inference: CSInferenceSettings()
        )

        return OneSequenceViewModel(sequence: sequence, chatService: chatService, settings: settings, chatSettingsService: chatSettingsService, appSettings: appSettings)
    }

    convenience init(_ sequence: ChatSequence, chatService: ChatSyncService, appSettings: AppSettings, chatSettingsService: CSCSettingsService) {
        self.init(sequence: sequence, chatService: chatService, settings: chatSettingsService.settings(for: sequence), chatSettingsService: chatSettingsService, appSettings: appSettings)
    }

    init(
        sequence: ChatSequence,
        chatService: ChatSyncService,
        settings: CSCSettingsService.SettingsProxy,
        chatSettingsService: CSCSettingsService,
        appSettings: AppSettings
    ) {
        self.sequence = sequence
        self.chatService = chatService
        self.settings = settings
        self.chatSettingsService = chatSettingsService
        self.appSettings = appSettings
    }

    var displayHumanDesc: String {
        return sequence.displayHumanDesc()
    }

    var displayServerStatus: String? {
        get {
            if serverStatus == nil || serverStatus!.isEmpty {
                return nil
            }

            return serverStatus
        }
    }

    private func completionHandler(
        caller callerName: String,
        endpoint: String
    ) -> ((Subscribers.Completion<AFErrorAndData>) -> Void) {
        return { [self] completion in
            _ = self.stayAwake.destroyAssertion()

            switch completion {
            case .finished:
                if responseInEdit == nil {
                    print("[ERROR] \(callerName) completed without any response data")
                }
                else {
                    sequence.messages.append(responseInEdit!)
                    responseInEdit = nil
                }
                stopSubmitAndReceive()
            case .failure(let errorAndData):
                responseInEdit = nil
                stopSubmitAndReceive()

                let errorDesc: String = (
                    String(data: errorAndData.data ?? Data(), encoding: .utf8)
                    ?? errorAndData.localizedDescription
                )
                serverStatus = "[\(Date.now)] \(endpoint) failure: " + errorDesc

                let errorMessage = Message(
                    role: "[ERROR] \(callerName): \(errorAndData.localizedDescription)",
                    content: responseInEdit?.content ?? errorDesc,
                    createdAt: Date.now
                )
                sequence.messages.append(errorMessage)
            }
        }
    }

    private func receiveHandler(
        caller callerName: String,
        endpoint: String,
        maybeNextMessage: Message? = nil
    ) -> ((Data) -> Void) {
        return { [self] data in
            // On first data received, end "submitting" phase
            if submitting {
                if maybeNextMessage != nil {
                    sequence.messages.append(maybeNextMessage!)
                }

                promptInEdit = ""
                submitting = false

                responseInEdit = Message(
                    role: "assistant",
                    content: submittedAssistantResponseSeed ?? "",
                    createdAt: Date.now
                )

                submittedAssistantResponseSeed = nil
            }

            serverStatus = "\(endpoint) response: (\(responseInEdit!.content.count) characters so far)"
            do {
                let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                if let status = jsonDict["status"] as? String {
                    serverStatus = status
                }

                if let message = jsonDict["message"] as? [String : Any] {
                    if let fragment = message["content"] as? String {
                        if !fragment.isEmpty {
                            DispatchQueue.main.async {
                                self.responseInEdit = self.responseInEdit!.appendContent(fragment)
                                self.objectWillChange.send()
                            }
                        }
                    }
                }

                if let done = jsonDict["done"] as? Bool {
                    let newSequenceId: ChatSequenceServerID? = jsonDict["new_sequence_id"] as? Int
                    if done && newSequenceId != nil {
                        Task {
                            await self.replaceSequence(newSequenceId!)
                        }
                    }
                }
            }
            catch {
                print("[ERROR] \(callerName): decoding error or something")
            }
        }
    }

    func requestStart(
        model continuationModelId: FoundationModelRecordID? = nil,
        withRetrieval: Bool = false
    ) -> Self {
        print("[INFO] OneSequenceViewModel.requestStart(\(continuationModelId), withRetrieval: \(withRetrieval))")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestStart() for ChatSequence#\(self.sequence.serverId ?? -1)")
        }

        Task {
            guard submitting == false else {
                print("[ERROR] OneSequenceViewModel.requestStart(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.serverStatus = "/sequences/[TBD]/extend: submitting request"
            }

            let messageId: ChatMessageServerID? = try? await chatService.constructChatMessage(from: TemporaryChatMessage(
                role: "user",
                content: promptInEdit,
                createdAt: Date.now
            ))
            guard messageId != nil else {
                submitting = false
                print("[ERROR] Couldn't construct ChatMessage from text: \(promptInEdit)")
                return
            }

            let sequenceId: ChatSequenceServerID? = try? await chatService.constructNewChatSequence(messageId: messageId!, humanDesc: "")
            guard sequenceId != nil else {
                submitting = false
                print("[ERROR] Couldn't construct sequence from: ChatMessage#\(messageId!)")
                return
            }
            sequence.serverId = sequenceId
            sequence.messages = [
                Message(
                    role: "user",
                    content: promptInEdit,
                    createdAt: Date.now
                )
            ]

            submittedAssistantResponseSeed = settings.seedAssistantResponse

            receivingStreamer = await chatService.sequenceContinue(
                ChatSequenceParameters(
                    nextMessage: nil,
                    continuationModelId: continuationModelId,
                    fallbackModelId: appSettings.fallbackInferenceModel?.serverId,
                    inferenceOptions: settings.inferenceOptions,
                    overrideModelTemplate: settings.overrideModelTemplate,
                    overrideSystemPrompt: settings.overrideSystemPrompt,
                    seedAssistantResponse: settings.seedAssistantResponse,
                    retrievalPolicy: withRetrieval ? settings.retrievalPolicy : nil,
                    retrievalSearchArgs: withRetrieval ? settings.retrievalSearchArgs : nil,
                    preferredEmbeddingModel: withRetrieval ? appSettings.preferredEmbeddingModel?.serverId : nil,
                    autonamingPolicy: settings.autonamingPolicy.rawValue,
                    preferredAutonamingModel: appSettings.chatSummaryModel?.serverId,
                    sequenceId: sequence.serverId!
                )
            )
                .sink(receiveCompletion: completionHandler(
                    caller: "ChatSyncService.sequenceContinue",
                    endpoint: "/sequences/\(sequence.serverId!)/continue"
                ), receiveValue: receiveHandler(
                    caller: "OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval))",
                    endpoint: "/sequences/\(sequence.serverId!)/continue"
                ))
        }

        return self
    }

    func requestContinue(
        model continuationModelId: FoundationModelRecordID? = nil,
        withRetrieval: Bool = false
    ) -> Self {
        print("[INFO] OneSequenceViewModel.requestContinue(\(continuationModelId), withRetrieval: \(withRetrieval))")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestContinue() for ChatSequence#\(self.sequence.serverId ?? -1)")
        }

        Task {
            guard submitting == false else {
                print("[ERROR] OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.serverStatus = "/sequences/\(self.sequence.serverId!)/continue: submitting request"
            }

            submittedAssistantResponseSeed = settings.seedAssistantResponse

            receivingStreamer = await chatService.sequenceContinue(
                ChatSequenceParameters(
                    nextMessage: nil,
                    continuationModelId: continuationModelId,
                    fallbackModelId: appSettings.fallbackInferenceModel?.serverId,
                    inferenceOptions: settings.inferenceOptions,
                    overrideModelTemplate: settings.overrideModelTemplate,
                    overrideSystemPrompt: settings.overrideSystemPrompt,
                    seedAssistantResponse: settings.seedAssistantResponse,
                    retrievalPolicy: withRetrieval ? settings.retrievalPolicy : nil,
                    retrievalSearchArgs: withRetrieval ? settings.retrievalSearchArgs : nil,
                    preferredEmbeddingModel: withRetrieval ? appSettings.preferredEmbeddingModel?.serverId : nil,
                    autonamingPolicy: settings.autonamingPolicy.rawValue,
                    preferredAutonamingModel: appSettings.chatSummaryModel?.serverId,
                    sequenceId: sequence.serverId!
                )
            )
                .sink(receiveCompletion: completionHandler(
                    caller: "ChatSyncService.sequenceContinue",
                    endpoint: "/sequences/\(sequence.serverId!)/continue"
                ), receiveValue: receiveHandler(
                    caller: "OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval))",
                    endpoint: "/sequences/\(sequence.serverId!)/continue"
                ))
        }

        return self
    }

    func requestExtend(
        model continuationModelId: FoundationModelRecordID? = nil,
        withRetrieval: Bool = false
    ) {
        print("[INFO] OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval))")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestExtend() for ChatSequence#\(self.sequence.serverId ?? -1)")
        }

        Task {
            guard !self.promptInEdit.isEmpty else { return }
            guard submitting == false else {
                print("[ERROR] OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.serverStatus = "/sequences/\(self.sequence.serverId!)/extend: submitting request"
            }

            let nextMessage = Message(
                role: "user",
                content: promptInEdit,
                createdAt: Date.now
            )

            submittedAssistantResponseSeed = settings.seedAssistantResponse

            receivingStreamer = await chatService.sequenceExtend(
                ChatSequenceParameters(
                    nextMessage: nextMessage,
                    continuationModelId: continuationModelId,
                    fallbackModelId: appSettings.fallbackInferenceModel?.serverId,
                    inferenceOptions: settings.inferenceOptions,
                    overrideModelTemplate: settings.overrideModelTemplate,
                    overrideSystemPrompt: settings.overrideSystemPrompt,
                    seedAssistantResponse: settings.seedAssistantResponse,
                    retrievalPolicy: withRetrieval ? settings.retrievalPolicy : nil,
                    retrievalSearchArgs: withRetrieval ? settings.retrievalSearchArgs : nil,
                    preferredEmbeddingModel: withRetrieval ? appSettings.preferredEmbeddingModel?.serverId : nil,
                    autonamingPolicy: settings.autonamingPolicy.rawValue,
                    preferredAutonamingModel: appSettings.chatSummaryModel?.serverId,
                    sequenceId: sequence.serverId!
                )
            )
            .sink(receiveCompletion: completionHandler(
                caller: "ChatSyncService.sequenceExtend",
                endpoint: "/sequences/\(sequence.serverId!)/extend"
            ), receiveValue: receiveHandler(
                caller: "OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval))",
                endpoint: "/sequences/\(sequence.serverId!)/extend",
                maybeNextMessage: nextMessage
            ))
        }
    }

    func stopSubmitAndReceive(userRequested: Bool = false) {
        receivingStreamer?.cancel()
        receivingStreamer = nil

        submitting = false
        serverStatus = nil

        if responseInEdit != nil {
            // TODO: There's all sort of error conditions we could/should actually check for.
            if !responseInEdit!.content.isEmpty {
                sequence.messages.append(responseInEdit!)
            }
            responseInEdit = nil

            if userRequested {
                serverStatus = "[WARNING] Requested stop of receive, but TODO: Ollama/server don't actually stop inference"
            }
        }
    }

    func replaceSequence(_ newSequenceId: ChatSequenceServerID) async {
        // If our original sequence.serverId was nil, we need to reset/reattach our Settings, too.
        let startedFromBlank = self.sequence.serverId == nil

        print("[DEBUG] Attempting to update OneSequenceViewModel to new_sequence_id: \(newSequenceId)")
        let newSequence = await self.chatService.updateSequence(self.sequence.serverId, withNewSequence: newSequenceId)

        if startedFromBlank && newSequence != nil {
            self.chatSettingsService.perSequenceUiSettings[newSequence!] = settings.override
            self.chatSettingsService.perSequenceInferenceSettings[newSequence!] = settings.inference
        }
    }
}

extension OneSequenceViewModel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
        hasher.combine(promptInEdit)
        hasher.combine(responseInEdit)
    }
}

extension OneSequenceViewModel: Equatable {
    static func == (lhs: OneSequenceViewModel, rhs: OneSequenceViewModel) -> Bool {
        if lhs.sequence != rhs.sequence {
            return false
        }

        if lhs.promptInEdit != rhs.promptInEdit {
            return false
        }

        if lhs.responseInEdit != rhs.responseInEdit {
            return false
        }

        return true
    }
}
