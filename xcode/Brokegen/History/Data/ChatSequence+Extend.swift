import Alamofire
import Combine
import Foundation
import SwiftData

struct ChatSequenceParameters: Codable, Hashable {
    let nextMessage: Message?
    let sequenceId: ChatSequenceServerID
    let sequence: ChatSequence?
    let continuationModelId: InferenceModelRecordID?
}

/// Finally, something to submit new chat requests
extension ChatSyncService {
    public func sequenceContinue(
        _ params: ChatSequenceParameters
    ) async -> AnyPublisher<Data, AFError> {
        let subject = PassthroughSubject<Data, AFError>()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            print("[DEBUG] POST /sequences/\(params.sequenceId)/continue <= \(String(data: try encoder.encode(params), encoding: .utf8)!)")

            _ = session.streamRequest(
                serverBaseURL + "/sequences/\(params.sequenceId)/continue"
            ) { urlRequest in
                urlRequest.method = .post
                urlRequest.headers = [
                    "Content-Type": "application/json"
                ]
                urlRequest.httpBody = try encoder.encode(params)
            }
            .responseStream { stream in
                switch stream.event {
                case let .stream(result):
                    switch result {
                    case let .success(data):
                        subject.send(data)
                    }
                case let .complete(completion):
                    if completion.error == nil {
                        subject.send(completion: .finished)
                    }
                    else {
                        subject.send(completion: .failure(completion.error!))
                    }
                }
            }
        }
        catch {
            print("[ERROR] /sequences/\(params.sequenceId)/continue failed, probably encoding error: \(String(describing: params))")
        }

        return subject.eraseToAnyPublisher()
    }

    public func sequenceExtend(
        _ params: ChatSequenceParameters
    ) async -> AnyPublisher<Data, AFError> {
        let subject = PassthroughSubject<Data, AFError>()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            print("[DEBUG] POST /sequences/\(params.sequenceId)/extend <= \(String(data: try encoder.encode(params), encoding: .utf8)!)")

            _ = session.streamRequest(
                serverBaseURL + "/sequences/\(params.sequenceId)/extend"
            ) { urlRequest in
                urlRequest.method = .post
                urlRequest.headers = [
                    "Content-Type": "application/json"
                ]
                urlRequest.httpBody = try encoder.encode(params)
            }
            .responseStream { stream in
                switch stream.event {
                case let .stream(result):
                    switch result {
                    case let .success(data):
                        subject.send(data)
                    }
                case let .complete(completion):
                    if completion.error == nil {
                        subject.send(completion: .finished)
                    }
                    else {
                        subject.send(completion: .failure(completion.error!))
                    }
                }
            }
        }
        catch {
            print("[ERROR] /sequences/\(params.sequenceId)/extend failed, probably encoding error: \(String(describing: params))")
        }

        return subject.eraseToAnyPublisher()
    }
}

@Observable
class ChatSequenceClientModel: Observable, ObservableObject {
    var sequence: ChatSequence
    let chatService: ChatSyncService

    var promptInEdit: String = ""
    var submitting: Bool = false

    var responseInEdit: Message? = nil
    var receiving: Bool = false
    var receivingStreamer: AnyCancellable? = nil

    init(_ sequence: ChatSequence, chatService: ChatSyncService) {
        self.sequence = sequence
        self.chatService = chatService
    }

    func requestContinue(
        model continuationModelId: InferenceModelRecordID? = nil
    ) -> Self {
        print("[INFO] ChatSequenceClientModel.submiwTithoutPrompt(\(continuationModelId))")

        Task.init {
            guard submitting == false else {
                print("[ERROR] OneSequenceView.submitWithoutPrompt during another submission")
                return
            }
            submitting = true

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
                    case .failure(let error):
                        let errorMessage = Message(
                            role: "[ERROR] ChatSyncService.sequenceContinue: \(error.localizedDescription)",
                            content: responseInEdit?.content ?? "",
                            createdAt: Date.now
                        )
                        sequence.messages.append(errorMessage)
                        responseInEdit = nil

                        stopSubmitAndReceive()
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
                    receiving = true

                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
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
                        print("[ERROR] OneSequenceView.submitWithoutPrompt: decoding error or something")
                    }
                })
        }

        return self
    }

    func requestExtend() {
        Task.init {
            /// TODO: Avoid race conditions by migrating to actor
            guard submitting == false else {
                print("[ERROR] OneSequenceView.submit during another submission")
                return
            }
            submitting = true

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
                        let errorMessage = Message(
                            role: "[ERROR] ChatSyncService.sequenceExtend: \(error.localizedDescription)",
                            content: responseInEdit?.content ?? "",
                            createdAt: Date.now
                        )
                        sequence.messages.append(errorMessage)
                        responseInEdit = nil

                        stopSubmitAndReceive()
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
                    receiving = true

                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
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
                        print("[ERROR] OneSequenceView.submit: decoding error or something")
                    }
                })
        }
    }

    func stopSubmitAndReceive() {
        receivingStreamer?.cancel()
        receivingStreamer = nil

        submitting = false
        receiving = false
    }

    func replaceSequence(_ newSequenceId: ChatSequenceServerID) {
        Task.init {
            print("[DEBUG] Attempting to update ChatSequenceClientModel to new_sequence_id: \(newSequenceId)")
            chatService.replaceSequence(sequence.serverId!, with: newSequenceId)

            if let newSequence = await chatService.fetchSequence(newSequenceId) {
                self.sequence = newSequence
            }
        }
    }
}
