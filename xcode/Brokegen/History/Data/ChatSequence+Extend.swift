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
