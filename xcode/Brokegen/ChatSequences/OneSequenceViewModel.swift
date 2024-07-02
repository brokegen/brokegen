import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

let maxPinChatSequenceDesc = 140

/// This class is usually owned by ChatSyncService.
/// Interesting side cases:
///
/// - on constructing a new Sequence, there's no ChatSequenceID from the server yet
/// - when constructing a response / having one sent down from the server, the ChatSequenceID is not created until the response is done sending.
///   as you might imagine, this gets _weird_.
///
@Observable
class OneSequenceViewModel: ObservableObject {
    var sequence: ChatSequence
    let chatService: ChatSyncService
    let settings: CSCSettingsService.SettingsProxy
    let chatSettingsService: CSCSettingsService
    let appSettings: AppSettings

    var promptInEdit: String = ""
    var submitting: Bool = false

    var responseInEdit: TemporaryChatMessage? = nil
    @ObservationIgnored private var receivedDone: Int = 0
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

    func refreshSequenceData() {
        Task {
            if let refreshedSequence = try? await chatService.fetchChatSequenceDetails(sequence.serverId) {
                DispatchQueue.main.async {
                    self.chatService.updateSequence(withSameId: refreshedSequence)
                }
            }
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
                if receivedDone != 1 {
                    print("[ERROR] \(callerName) completed, but received \(receivedDone) \"done\" chunks")
                }
                if responseInEdit != nil {
                    print("[ERROR] \(callerName) completed early, storing response message as temporary")
                    sequence.messages.append(.temporary(responseInEdit!))
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

                let errorMessage = TemporaryChatMessage(
                    role: "[ERROR] \(callerName): \(errorAndData.localizedDescription)",
                    content: responseInEdit?.content ?? errorDesc,
                    createdAt: Date.now
                )
                sequence.messages.append(.temporary(errorMessage))
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
                submitting = false

                if maybeNextMessage != nil {
                    sequence.messages.append(.legacy(maybeNextMessage!))
                }
                promptInEdit = ""

                receivedDone = 0
                responseInEdit = TemporaryChatMessage(
                    role: "assistant",
                    content: submittedAssistantResponseSeed ?? "",
                    createdAt: Date.now
                )

                submittedAssistantResponseSeed = nil

                // NB Don't live-update this; any direct SwiftUI updates from here will be very slow.
                // This is possibly because status bar rendering is implemented wrong, but not worth investigating.
                serverStatus = "\(endpoint): awaiting response"
            }

            let jsonData: JSON = JSON(data)

            if let status = jsonData["status"].string {
                serverStatus = status
            }

            let messageFragment = jsonData["message"]["content"].stringValue
            if !messageFragment.isEmpty {
                DispatchQueue.main.async {
                    self.responseInEdit!.content?.append(messageFragment)
                }
            }

            if jsonData["done"].boolValue {
                receivedDone += 1
            }

            if let newMessageId: ChatMessageServerID = jsonData["new_message_id"].int {
                if responseInEdit != nil {
                    let storedMessage = ChatMessage(
                        serverId: newMessageId,
                        hostSequenceId: sequence.serverId,
                        role: responseInEdit!.role,
                        content: responseInEdit!.content ?? "",
                        createdAt: responseInEdit!.createdAt
                    )

                    sequence.messages.append(.stored(storedMessage))
                    responseInEdit = nil
                }
            }

            if let replacementSequenceId: ChatSequenceServerID = jsonData["new_sequence_id"].int {
                let originalSequenceId = self.sequence.serverId
                let updatedSequence = self.sequence.replaceServerId(replacementSequenceId)

                DispatchQueue.main.async {
                    self.chatService.updateSequenceOffline(originalSequenceId, withReplacement: updatedSequence)
                }
            }

            let autoname: String = jsonData["autoname"].stringValue
            if !autoname.isEmpty && autoname != sequence.humanDesc {
                let renamedSequence = sequence.replaceHumanDesc(desc: autoname)
                DispatchQueue.main.async {
                    self.chatService.updateSequence(withSameId: renamedSequence)
                }
            }
        }
    }

    func requestContinue(
        model continuationModelId: FoundationModelRecordID? = nil,
        withRetrieval: Bool = false
    ) -> Self {
        print("[INFO] OneSequenceViewModel.requestContinue(\(continuationModelId), withRetrieval: \(withRetrieval))")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestContinue() for ChatSequence#\(self.sequence.serverId)")
        }

        Task {
            guard !submitting else {
                print("[ERROR] OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            guard !receiving else {
                print("[ERROR] OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval)) while receiving response")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.serverStatus = "/sequences/\(self.sequence.serverId)/continue: submitting request"
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
                    preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId,
                    sequenceId: sequence.serverId
                )
            )
                .sink(receiveCompletion: completionHandler(
                    caller: "ChatSyncService.sequenceContinue",
                    endpoint: "/sequences/\(sequence.serverId)/continue"
                ), receiveValue: receiveHandler(
                    caller: "OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval))",
                    endpoint: "/sequences/\(sequence.serverId)/continue"
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
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestExtend() for ChatSequence#\(self.sequence.serverId)")
        }

        Task {
            guard !self.promptInEdit.isEmpty else { return }
            guard !submitting else {
                print("[ERROR] OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            guard !receiving else {
                print("[ERROR] OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval)) while receiving response")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.serverStatus = "/sequences/\(self.sequence.serverId)/extend: submitting request"
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
                    preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId,
                    sequenceId: sequence.serverId
                )
            )
            .sink(receiveCompletion: completionHandler(
                caller: "ChatSyncService.sequenceExtend",
                endpoint: "/sequences/\(sequence.serverId)/extend"
            ), receiveValue: receiveHandler(
                caller: "OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval))",
                endpoint: "/sequences/\(sequence.serverId)/extend",
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
            if !(responseInEdit!.content ?? "").isEmpty {
                sequence.messages.append(.temporary(responseInEdit!))
            }
            responseInEdit = nil

            if userRequested {
                serverStatus = "[WARNING] Requested stop of receive, but TODO: Ollama/server don't actually stop inference"
            }
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
