import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

struct ChatSequenceParameters: Codable, Hashable {
    let nextMessage: Message?
    let continuationModelId: InferenceModelRecordID?
    let fallbackModelId: InferenceModelRecordID?

    /// TODO: options could probably be a JSON
    var inferenceOptions: String? = nil
    var overrideSystemPrompt: String? = nil
    var seedAssistantResponse: String? = nil

    var retrievalPolicy: String? = nil
    var retrievalSearchArgs: String? = nil
    var preferredEmbeddingModel: InferenceModelRecordID? = nil

    var autonamingPolicy: String? = nil
    var preferredAutonamingModel: InferenceModelRecordID? = nil

    // These parameters shouldn't be passed to the server,
    // but the information is needed to complete the request.
    //
    // Since I don't want to make four separate structs, they're passed to the server anyway.
    //
    let sequenceId: ChatSequenceServerID
}

struct AFErrorAndData: Error {
    let error: AFError
    let data: Data?

    public var localizedDescription: String {
        get { return error.localizedDescription }
    }
}

/// Finally, something to submit new chat requests
extension DefaultChatSyncService {
    public func doSequenceContinue(
        _ params: ChatSequenceParameters
    ) async -> AnyPublisher<Data, AFErrorAndData> {
        let subject = PassthroughSubject<Data, AFErrorAndData>()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        /// TODO: Confirm that ChatMessages get uploaded with a non-1993 date!
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions.insert(.withFractionalSeconds)

            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }

        var encodedParams: Data? = nil
        do {
            // TODO: Replace with jsonEncoder
            encodedParams = try encoder.encode(params)
        }
        catch {
            print("[ERROR] /sequences/\(params.sequenceId)/continue failed, probably encoding error: \(String(describing: params))")
            return subject.eraseToAnyPublisher()
        }

        print("[DEBUG] POST /sequences/\(params.sequenceId)/continue <= \(String(data: encodedParams!, encoding: .utf8)!)")
        var responseStatusCode: Int? = nil

        _ = session.streamRequest(
            serverBaseURL + "/sequences/\(params.sequenceId)/continue"
        ) { urlRequest in
            urlRequest.method = .post
            urlRequest.headers = [
                "Content-Type": "application/json"
            ]
            urlRequest.httpBody = encodedParams!
        }
        .onHTTPResponse { response in
            // Status code comes early on, but we need to wait for a .response handler to get body data.
            // Store the status code until the later handler can deal with it.
            responseStatusCode = response.statusCode
        }
        .responseStream { stream in
            switch stream.event {
            case let .stream(result):
                switch result {
                case let .success(data):
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        let error = AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: responseStatusCode!))
                        subject.send(completion: .failure(AFErrorAndData(error: error, data: data)))
                    }
                    else {
                        subject.send(data)
                    }
                }
            case let .complete(completion):
                if completion.error == nil {
                    subject.send(completion: .finished)
                }
                else {
                    subject.send(completion: .failure(AFErrorAndData(error: completion.error!, data: nil)))
                }
            }
        }

        return subject.eraseToAnyPublisher()
    }

    public func doSequenceExtend(
        _ params: ChatSequenceParameters
    ) async -> AnyPublisher<Data, AFErrorAndData> {
        let subject = PassthroughSubject<Data, AFErrorAndData>()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        /// TODO: Confirm that ChatMessages get uploaded with a non-1993 date!
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions.insert(.withFractionalSeconds)

            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }

        var encodedParams: Data? = nil
        do {
            encodedParams = try encoder.encode(params)
        }
        catch {
            print("[ERROR] /sequences/\(params.sequenceId)/extend failed, probably encoding error: \(String(describing: params))")
            return subject.eraseToAnyPublisher()
        }

        print("[DEBUG] POST /sequences/\(params.sequenceId)/extend <= \(String(data: encodedParams!, encoding: .utf8)!)")
        var responseStatusCode: Int? = nil

        _ = session.streamRequest(
            serverBaseURL + "/sequences/\(params.sequenceId)/extend"
        ) { urlRequest in
            urlRequest.method = .post
            urlRequest.headers = [
                "Content-Type": "application/json"
            ]
            urlRequest.httpBody = encodedParams!
        }
        .onHTTPResponse { response in
            // Status code comes early on, but we need to wait for a .response handler to get body data.
            // Store the status code until the later handler can deal with it.
            responseStatusCode = response.statusCode
        }
        .responseStream { stream in
            switch stream.event {
            case let .stream(result):
                switch result {
                case let .success(data):
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        let error = AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: responseStatusCode!))
                        subject.send(completion: .failure(AFErrorAndData(error: error, data: data)))
                    }
                    else {
                        subject.send(data)
                    }
                }
            case let .complete(completion):
                if completion.error == nil {
                    subject.send(completion: .finished)
                }
                else {
                    subject.send(completion: .failure(AFErrorAndData(error: completion.error!, data: nil)))
                }
            }
        }

        return subject.eraseToAnyPublisher()
    }
}
