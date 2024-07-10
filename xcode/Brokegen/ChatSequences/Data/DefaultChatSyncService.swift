import Alamofire
import Combine
import Foundation
import SwiftyJSON

class DefaultChatSyncService: ChatSyncService {
    let dateFormatter: ISO8601DateFormatter

    var serverBaseURL: String
    let session: Alamofire.Session

    init(_ serverBaseURL: String, configuration: URLSessionConfiguration) {
        self.serverBaseURL = serverBaseURL
        self.session = Alamofire.Session(configuration: configuration)

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions.insert(.withFractionalSeconds)
    }

    // MARK: - ChatSequence construction
    override public func constructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID? {
        return try await doConstructChatMessage(from: tempMessage)
    }

    override public func saveTo(sequence: ChatSequence, messageId: ChatMessageServerID) async throws -> ChatSequenceServerID? {
        return try await doSaveTo(sequence: sequence, messageId: messageId)
    }

    override public func constructNewChatSequence(messageId: ChatMessageServerID, humanDesc: String = "") async throws -> ChatSequenceServerID? {
        return try await doConstructNewChatSequence(messageId: messageId, humanDesc: humanDesc)
    }

    override public func fetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        return try await doFetchChatSequenceDetails(sequenceId)
    }

    override func autonameChatSequence(_ sequence: ChatSequence, preferredAutonamingModel: FoundationModelRecordID?) -> String? {
        Task {
            var endpointBuilder = "/sequences/\(sequence.serverId)/autoname?wait_for_response=true"
            if preferredAutonamingModel != nil {
                endpointBuilder += "&preferred_autonaming_model=\(preferredAutonamingModel!)"
            }

            if let resultData: Data = try? await self.postDataBlocking(nil, endpoint: endpointBuilder) {
                if let autoname: String = JSON(resultData)["autoname"].string {
                    let autonamedSequence = sequence.replaceHumanDesc(desc: autoname)
                    DispatchQueue.main.async {
                        self.updateSequence(withSameId: autonamedSequence)
                    }
                }
            }
        }

        return nil
    }

    override func renameChatSequence(_ sequence: ChatSequence, to newHumanDesc: String?) async -> ChatSequence? {
        guard newHumanDesc != sequence.humanDesc else { return nil }

        _ = try? await self.postDataBlocking(
            nil,
            endpoint: "/sequences/\(sequence.serverId)/human_desc?value=\(newHumanDesc ?? "")")

        return sequence.replaceHumanDesc(desc: newHumanDesc)
    }

    override func pinChatSequence(
        _ sequence: ChatSequence,
        pinned userPinned: Bool
    ) {
        guard userPinned != sequence.userPinned else { return }

        Task {
            let result = try? await self.postDataBlocking(
                nil,
                endpoint: "/sequences/\(sequence.serverId)/user_pinned?value=\(userPinned)")
            guard result != nil else { return }

            let updatedSequence = sequence.replaceUserPinned(pinned: userPinned)
            DispatchQueue.main.async {
                self.updateSequence(withSameId: updatedSequence)
            }
        }
    }

    // MARK: - ChatSequence change members
    override public func fetchRecents(lookback: TimeInterval?, limit: Int?, onlyUserPinned: Bool?) async throws {
        return try await doFetchRecents(
            lookback: lookback,
            limit: limit,
            includeUserPinned: true,
            includeLeafSequences: !(onlyUserPinned ?? false),
            includeAll: !(onlyUserPinned ?? false)
        )
    }

    // MARK: - ChatSequence extend/continue
    override public func sequenceContinue(_ params: ChatSequenceParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        return await doSequenceContinue(params)
    }

    override public func sequenceExtend(_ params: ChatSequenceParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        return await doSequenceExtend(params)
    }
}

// MARK: - HTTP GET/POST Functions
extension DefaultChatSyncService {
    func getDataBlocking(_ endpoint: String) async throws -> Data? {
        print("[TRACE] GET \(endpoint)")
        var responseStatusCode: Int? = nil

        let receiveQueue = DispatchQueue(label: "brokegen server", qos: .background, attributes: .concurrent)

        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                serverBaseURL + endpoint,
                method: .get
            )
            .onHTTPResponse { response in
                // Status code comes early on, but we need to wait for a .response handler to get body data.
                // Store the status code until the later handler can deal with it.
                responseStatusCode = response.statusCode
            }
            .response(queue: receiveQueue) { r in
                switch r.result {
                case .success(let data):
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        continuation.resume(throwing: ChatSyncServiceError.invalidResponseStatusCode(responseStatusCode!, data: data))
                        return
                    }

                    if data != nil {
                        continuation.resume(returning: data!)
                    }
                    else {
                        continuation.resume(throwing: ChatSyncServiceError.noResponseContentReturned)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func postDataBlocking(_ httpBody: Data?, endpoint: String) async throws -> Data {
        print("[TRACE] POST \(endpoint)")
        var responseStatusCode: Int? = nil

        let receiveQueue = DispatchQueue(label: "brokegen server", qos: .background, attributes: .concurrent)

        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                serverBaseURL + endpoint
            ) { urlRequest in
                urlRequest.method = .post
                urlRequest.headers = [
                    "Content-Type": "application/json",
                ]
                urlRequest.httpBody = httpBody
            }
            .onHTTPResponse { response in
                responseStatusCode = response.statusCode
            }
            .response(queue: receiveQueue) { r in
                switch r.result {
                case .success(let data):
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        continuation.resume(throwing: ChatSyncServiceError.invalidResponseStatusCode(responseStatusCode!, data: data))
                        return
                    }

                    if data != nil {
                        continuation.resume(returning: data!)
                    }
                    else {
                        continuation.resume(throwing: ChatSyncServiceError.noResponseContentReturned)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
