import Alamofire
import Combine
import Foundation
import SwiftData

let maxPinChatSequenceDesc = 140

@Observable
class OneSequenceViewModel: ObservableObject {
    var sequence: ChatSequence
    let chatService: ChatSyncService
    let inferenceModelSettings: InferenceModelSettings
    var settings: CSCSettingsService.SettingsProxy

    var promptInEdit: String = ""
    var submitting: Bool = false

    /// This field does double duty to indicate whether we are currently receiving data.
    /// `nil` before first data, and then reset to `nil` once we're done receiving.
    var responseInEdit: Message? = nil
    var receivingStreamer: AnyCancellable? = nil
    var serverStatus: String? = nil

    private var stayAwake: StayAwake = StayAwake()
    var currentlyAwakeDuringInference: Bool {
        get { stayAwake.assertionIsActive }
    }

    var showTextEntryView: Bool = true
    var showUiOptions: Bool = false
    var showInferenceOptions: Bool = false
    var showRetrievalOptions: Bool = false

    var showAssistantResponseSeed: Bool = false
    var showSystemPromptOverride: Bool = false

    init(_ sequence: ChatSequence, chatService: ChatSyncService, inferenceModelSettings: InferenceModelSettings, chatSettingsService: CSCSettingsService) {
        self.sequence = sequence
        self.chatService = chatService
        self.inferenceModelSettings = inferenceModelSettings
        self.settings = chatSettingsService.settings(for: sequence)
    }

    var displayHumanDesc: String {
        if !(sequence.humanDesc ?? "").isEmpty {
            return sequence.humanDesc!
        }

        return "ChatSequence#\(sequence.serverId!)"
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
                    content: "",
                    createdAt: Date.now
                )
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
                            responseInEdit = responseInEdit!.appendContent(fragment)
                            objectWillChange.send()
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

    func requestContinue(
        model continuationModelId: InferenceModelRecordID? = nil,
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

            receivingStreamer = await chatService.sequenceContinue(
                ChatSequenceParameters(
                    nextMessage: nil,
                    continuationModelId: continuationModelId,
                    fallbackModelId: inferenceModelSettings.fallbackInferenceModel?.serverId,
                    retrievalPolicy: withRetrieval ? "simple" : nil,
                    retrievalSearchArgs: withRetrieval ? "{\"k\": 18}" : nil,
                    preferredEmbeddingModel: withRetrieval ? inferenceModelSettings.preferredEmbeddingModel?.serverId : nil,
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

            receivingStreamer = await chatService.sequenceExtend(
                ChatSequenceParameters(
                    nextMessage: nextMessage,
                    continuationModelId: nil,
                    fallbackModelId: inferenceModelSettings.fallbackInferenceModel?.serverId,
                    retrievalPolicy: withRetrieval ? "simple" : nil,
                    retrievalSearchArgs: withRetrieval ? "{\"k\": 18}" : nil,
                    preferredEmbeddingModel: withRetrieval ? inferenceModelSettings.preferredEmbeddingModel?.serverId : nil,
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
        print("[DEBUG] Attempting to update OneSequenceViewModel to new_sequence_id: \(newSequenceId)")
        await self.chatService.updateSequence(self.sequence.serverId!, withNewSequence: newSequenceId)

        if let newSequence = try? await chatService.fetchChatSequenceDetails(newSequenceId) {
            DispatchQueue.main.async {
                self.sequence = newSequence
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
