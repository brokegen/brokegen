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

    var promptInEdit: String = ""
    var submitting: Bool = false

    /// This field does double duty to indicate whether we are currently receiving data.
    /// `nil` before first data, and then reset to `nil` once we're done receiving.
    var responseInEdit: Message? = nil
    var receivingStreamer: AnyCancellable? = nil

    var displayedStatus: String? = nil

    init(_ sequence: ChatSequence, chatService: ChatSyncService) {
        self.sequence = sequence
        self.chatService = chatService
    }

    func requestContinue(
        model continuationModelId: InferenceModelRecordID? = nil
    ) -> Self {
        print("[INFO] ChatSequenceClientModel.requestContinue(\(continuationModelId))")

        Task.init {
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.requestContinue during another submission")
                return
            }
            submitting = true
            displayedStatus = "/sequences/\(sequence.serverId!)/continue: submitting request"

            receivingStreamer = await chatService.sequenceContinue(
                ChatSequenceParameters(
                    nextMessage: nil,
                    sequenceId: sequence.serverId!,
                    sequence: nil,
                    continuationModelId: continuationModelId))
                .sink(receiveCompletion: { [self] completion in
                    switch completion {
                    case .finished:
                        if responseInEdit == nil {
                            print("[ERROR] ChatSyncService.sequenceContinue completed without any response data")
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
                        displayedStatus = "[\(Date.now)] /sequences/\(sequence.serverId!)/extend failure: " + errorDesc

                        let errorMessage = Message(
                            role: "[ERROR] ChatSyncService.sequenceContinue: \(errorAndData.localizedDescription)",
                            content: responseInEdit?.content ?? errorDesc,
                            createdAt: Date.now
                        )
                        sequence.messages.append(errorMessage)
                    }
                }, receiveValue: { [self] data in
                    // On first data received, end "submitting" phase
                    if submitting {
                        promptInEdit = ""
                        submitting = false

                        responseInEdit = Message(
                            role: "assistant",
                            content: "",
                            createdAt: Date.now
                        )
                    }

                    displayedStatus = "/sequences/\(sequence.serverId!)/continue response: (\(responseInEdit!.content.count) characters so far)"
                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                        if let status = jsonDict["status"] as? String {
                            displayedStatus = status
                        }

                        if let message = jsonDict["message"] as? [String : Any] {
                            if let fragment = message["content"] as? String {
                                responseInEdit = responseInEdit!.appendContent(fragment)
                            }
                        }

                        if let done = jsonDict["done"] as? Bool {
                            let newSequenceId: ChatSequenceServerID? = jsonDict["new_sequence_id"] as? Int
                            if done && newSequenceId != nil {
                                self.replaceSequence(newSequenceId!)
                            }
                        }
                    }
                    catch {
                        print("[ERROR] ChatSequenceClientModel.requestContinue: decoding error or something")
                    }
                })
        }

        return self
    }

    func requestExtend() {
        Task.init {
            guard !self.promptInEdit.isEmpty else { return }
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.requestExtend during another submission")
                return
            }
            submitting = true
            displayedStatus = "/sequences/\(sequence.serverId!)/extend: submitting request"

            let nextMessage = Message(
                role: "user",
                content: promptInEdit,
                createdAt: Date.now
            )

            receivingStreamer = await chatService.sequenceExtend(
                ChatSequenceParameters(
                    nextMessage: nextMessage,
                    sequenceId: sequence.serverId!,
                    sequence: nil,
                    continuationModelId: nil))
                .sink(receiveCompletion: { [self] completion in
                    switch completion {
                    case .finished:
                        if responseInEdit == nil {
                            print("[ERROR] ChatSyncService.sequenceExtend completed without any response data")
                        }
                        else {
                            sequence.messages.append(responseInEdit!)
                            responseInEdit = nil
                        }
                        stopSubmitAndReceive()
                    case .failure(let error):
                        responseInEdit = nil
                        stopSubmitAndReceive()

                        displayedStatus = "[\(Date.now)] /sequences/\(sequence.serverId!)/extend failure: " + error.localizedDescription
                    }
                }, receiveValue: { [self] data in
                    // On first data received, end "submitting" phase
                    if submitting {
                        sequence.messages.append(nextMessage)

                        promptInEdit = ""
                        submitting = false

                        responseInEdit = Message(
                            role: "assistant",
                            content: "",
                            createdAt: Date.now
                        )
                    }

                    displayedStatus = "/sequences/\(sequence.serverId!)/extend response: (\(responseInEdit!.content.count) characters so far)"
                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                        if let status = jsonDict["status"] as? String {
                            displayedStatus = status
                        }

                        if let message = jsonDict["message"] as? [String : Any] {
                            if let fragment = message["content"] as? String {
                                responseInEdit = responseInEdit!.appendContent(fragment)
                            }
                        }

                        if let done = jsonDict["done"] as? Bool {
                            let newSequenceId: ChatSequenceServerID? = jsonDict["new_sequence_id"] as? Int
                            if done && newSequenceId != nil {
                                self.replaceSequence(newSequenceId!)
                            }
                        }
                    }
                    catch {
                        print("[ERROR] ChatSequenceClientModel.sequenceExtend: decoding error or something")
                    }
                })
        }
    }

    func requestExtendWithRetrieval() {
        Task.init {
            guard !self.promptInEdit.isEmpty else { return }
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.requestExtendWithRetrieval during another submission")
                return
            }
            submitting = true
            displayedStatus = "/sequences/\(sequence.serverId!)/extend: submitting request"

            let nextMessage = Message(
                role: "user",
                content: promptInEdit,
                createdAt: Date.now
            )

            receivingStreamer = await chatService.sequenceExtend(
                ChatSequenceParameters(
                    nextMessage: nextMessage,
                    sequenceId: sequence.serverId!,
                    sequence: nil,
                    continuationModelId: nil,
                    retrievalPolicy: "simple",
                    retrievalSearchArgs: "{\"k\": 18}"
                )
            )
                .sink(receiveCompletion: { [self] completion in
                    switch completion {
                    case .finished:
                        if responseInEdit == nil {
                            print("[ERROR] ChatSyncService.sequenceExtend completed without any response data")
                        }
                        else {
                            sequence.messages.append(responseInEdit!)
                            responseInEdit = nil
                        }
                        stopSubmitAndReceive()
                    case .failure(let error):
                        responseInEdit = nil
                        stopSubmitAndReceive()

                        displayedStatus = "[\(Date.now)] /sequences/\(sequence.serverId!)/extend failure: " + error.localizedDescription
                    }
                }, receiveValue: { [self] data in
                    // On first data received, end "submitting" phase
                    if submitting {
                        sequence.messages.append(nextMessage)

                        promptInEdit = ""
                        submitting = false

                        responseInEdit = Message(
                            role: "assistant",
                            content: "",
                            createdAt: Date.now
                        )
                    }

                    displayedStatus = "/sequences/\(sequence.serverId!)/extend response: (\(responseInEdit!.content.count) characters so far)"
                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                        if let status = jsonDict["status"] as? String {
                            displayedStatus = status
                        }

                        if let message = jsonDict["message"] as? [String : Any] {
                            if let fragment = message["content"] as? String {
                                responseInEdit = responseInEdit!.appendContent(fragment)
                            }
                        }

                        if let done = jsonDict["done"] as? Bool {
                            let newSequenceId: ChatSequenceServerID? = jsonDict["new_sequence_id"] as? Int
                            if done && newSequenceId != nil {
                                self.replaceSequence(newSequenceId!)
                            }
                        }
                    }
                    catch {
                        print("[ERROR] ChatSequenceClientModel.sequenceExtend: decoding error or something")
                    }
                })
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

    func replaceSequence(_ newSequenceId: ChatSequenceServerID) {
        Task.init {
            print("[DEBUG] Attempting to update ChatSequenceClientModel to new_sequence_id: \(newSequenceId)")
            chatService.replaceSequenceById(sequence.serverId!, with: newSequenceId)

            if let newSequence = await chatService.fetchSequence(newSequenceId) {
                self.sequence = newSequence
            }
        }
    }
}

