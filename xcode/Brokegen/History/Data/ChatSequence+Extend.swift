import Alamofire
import Combine
import Foundation
import SwiftData

struct ChatSequenceParameters: Codable, Hashable {
    let nextMessage: Message?
    let sequenceId: ChatSequenceServerID
    let sequence: ChatSequence?
    let continuationModelId: InferenceModelRecordID?
    var retrievalPolicy: String? = nil
    var retrievalSearchArgs: String? = nil
}

/// Finally, something to submit new chat requests
extension ChatSyncService {
    public func sequenceContinue(
        _ params: ChatSequenceParameters
    ) async -> AnyPublisher<Data, AFError> {
        let subject = PassthroughSubject<Data, AFError>()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        /// TODO: Confirm that ChatMessages get uploaded with a non-1993 date!
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions.insert(.withFractionalSeconds)

            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }

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

    /// This field does double duty to indicate whether we are currently receiving data.
    /// `nil` before first data, and then reset to `nil` once we're done receiving.
    var responseInEdit: Message? = nil
    var receivingStreamer: AnyCancellable? = nil

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
                        print("[ERROR] ChatSequenceClientModel.requestContinue: decoding error or something")
                    }
                })
        }

        return self
    }

    func requestExtend() {
        Task.init {
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.requestExtend during another submission")
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
                        print("[ERROR] ChatSequenceClientModel.sequenceExtend: decoding error or something")
                    }
                })
        }
    }

    func requestExtendWithRetrieval() {
        Task.init {
            guard submitting == false else {
                print("[ERROR] ChatSequenceClientModel.sequenceExtend during another submission")
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
                    continuationModelId: nil,
                    retrievalPolicy: "custom",
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
                        print("[ERROR] ChatSequenceClientModel.sequenceExtend: decoding error or something")
                    }
                })
        }
    }

    func stopSubmitAndReceive() {
        receivingStreamer?.cancel()
        receivingStreamer = nil

        submitting = false
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
