import Alamofire
import Combine
import Foundation
import SwiftData

// TODO: Keep active Models around, rather than constructing one.
// This probably means it has to live under ChatSyncService.
@Observable
class ChatSequenceClientModel: Observable, ObservableObject {
    var sequence: ChatSequence
    let chatService: ChatSyncService
    let inferenceModelSettings: InferenceModelSettings

    var pinSequenceTitle: Bool

    var promptInEdit: String = ""
    var submitting: Bool = false

    /// This field does double duty to indicate whether we are currently receiving data.
    /// `nil` before first data, and then reset to `nil` once we're done receiving.
    var responseInEdit: Message? = nil
    var receivingStreamer: AnyCancellable? = nil

    var displayedStatus: String? = nil

    init(_ sequence: ChatSequence, chatService: ChatSyncService, inferenceModelSettings: InferenceModelSettings) {
        self.sequence = sequence
        self.chatService = chatService
        self.inferenceModelSettings = inferenceModelSettings

        self.pinSequenceTitle = sequence.humanDesc != nil
    }

    var displayHumanDesc: String {
        if !(sequence.humanDesc ?? "").isEmpty {
            return sequence.humanDesc!
        }

        return "ChatSequence#\(sequence.serverId!)"
    }

    private func completionHandler(
        caller callerName: String,
        endpoint: String
    ) -> ((Subscribers.Completion<AFErrorAndData>) -> Void) {
        return { [self] completion in
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
                displayedStatus = "[\(Date.now)] \(endpoint) failure: " + errorDesc

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

            displayedStatus = "\(endpoint) response: (\(responseInEdit!.content.count) characters so far)"
            do {
                let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                if let status = jsonDict["status"] as? String {
                    displayedStatus = status
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
        print("[INFO] ChatSequenceClientModel.requestContinue(\(continuationModelId), withRetrieval: \(withRetrieval))")

        Task.init {
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.requestContinue(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.displayedStatus = "/sequences/\(self.sequence.serverId!)/continue: submitting request"
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
                    caller: "ChatSequenceClientModel.requestContinue(withRetrieval: \(withRetrieval))",
                    endpoint: "/sequences/\(sequence.serverId!)/continue"
                ))
        }

        return self
    }

    func requestExtend(
        withRetrieval: Bool = false
    ) {
        Task.init {
            guard !self.promptInEdit.isEmpty else { return }
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.requestExtend(withRetrieval: \(withRetrieval)) during another submission")
                return
            }
            DispatchQueue.main.async {
                self.submitting = true
                self.displayedStatus = "/sequences/\(self.sequence.serverId!)/extend: submitting request"
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
                caller: "ChatSequenceClientModel.requestExtend(withRetrieval: \(withRetrieval))",
                endpoint: "/sequences/\(sequence.serverId!)/extend",
                maybeNextMessage: nextMessage
            ))
        }
    }

    func stopSubmitAndReceive(userRequested: Bool = false) {
        receivingStreamer?.cancel()
        receivingStreamer = nil

        submitting = false
        displayedStatus = nil

        if responseInEdit != nil {
            sequence.messages.append(responseInEdit!)
            responseInEdit = nil

            if userRequested {
                displayedStatus = "[WARNING] Requested stop of receive, but TODO: Ollama/server don't actually stop inference"
            }
        }
    }

    func replaceSequence(_ newSequenceId: ChatSequenceServerID) async {
        print("[DEBUG] Attempting to update ChatSequenceClientModel to new_sequence_id: \(newSequenceId)")
        await self.chatService.replaceSequenceById(self.sequence.serverId!, with: newSequenceId)

        if let newSequence = await chatService.fetchSequence(newSequenceId) {
            DispatchQueue.main.async {
                self.sequence = newSequence
            }
        }
    }
}

extension ChatSequenceClientModel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
        hasher.combine(promptInEdit)
        hasher.combine(responseInEdit)
    }
}

extension ChatSequenceClientModel: Equatable {
    static func == (lhs: ChatSequenceClientModel, rhs: ChatSequenceClientModel) -> Bool {
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
