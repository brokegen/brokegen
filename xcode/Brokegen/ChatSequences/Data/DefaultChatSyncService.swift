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

    override public func constructNewChatSequence(messageId: ChatMessageServerID, humanDesc: String = "") async throws -> ChatSequenceServerID? {
        return try await doConstructNewChatSequence(messageId: messageId, humanDesc: humanDesc)
    }

    override public func appendMessage(sequence: ChatSequence, messageId: ChatMessageServerID) async throws -> ChatSequenceServerID? {
        return try await doAppendMessage(sequence: sequence, messageId: messageId)
    }

    override public func fetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        return try await doFetchChatSequenceDetails(sequenceId)
    }

    // TODO: Mark this as requiring @MainActor
    override func autonameBlocking(
        sequenceId: ChatSequenceServerID,
        preferredAutonamingModel: FoundationModelRecordID?
    ) async throws -> String? {
        var endpointBuilder = "/sequences/\(sequenceId)/autoname?wait_for_response=true"
        if preferredAutonamingModel != nil {
            endpointBuilder += "&preferred_autonaming_model=\(preferredAutonamingModel!)"
        }

        if let resultData: Data = try? await self.postDataBlocking(nil, endpoint: endpointBuilder) {
            if let autoname: String = JSON(resultData)["autoname"].string {
                // NB We explicitly "re-load" the ChatSequence info because `await` takes time.
                let autonamedSequence: ChatSequence? = self.loadedChatSequences[sequenceId]?
                    .replaceHumanDesc(desc: autoname)
                guard autonamedSequence != nil else { return nil }

                self.updateSequence(withSameId: autonamedSequence!)
                return autonamedSequence?.humanDesc
            }
        }

        return nil
    }

    // TODO: Mark this as requiring @MainActor
    override func renameBlocking(
        sequenceId: ChatSequenceServerID,
        to newHumanDesc: String?
    ) async throws -> ChatSequence? {
        let sequence: ChatSequence? = loadedChatSequences[sequenceId]
        guard sequence != nil else { return nil }
        guard newHumanDesc != sequence!.humanDesc else { return nil }

        _ = try await self.postDataBlocking(
            nil,
            endpoint: "/sequences/\(sequenceId)/human_desc?value=\(newHumanDesc ?? "")")

        // NB We explicitly "re-load" the ChatSequence info because `await` takes time.
        let updatedSequence: ChatSequence? = self.loadedChatSequences[sequenceId]?
            .replaceHumanDesc(desc: newHumanDesc)
        guard updatedSequence != nil else { return nil }

        self.updateSequence(withSameId: updatedSequence!)
        print("[TRACE] Finished rename to \(updatedSequence!.displayRecognizableDesc(replaceNewlines: true))")
        return updatedSequence
    }

    override func pin(
        sequenceId: ChatSequenceServerID,
        pinned userPinned: Bool
    ) {
        let sequence: ChatSequence? = loadedChatSequences[sequenceId]
        guard sequence != nil else { return }
        guard userPinned != sequence!.userPinned else { return }

        Task {
            let result = try? await self.postDataBlocking(
                nil,
                endpoint: "/sequences/\(sequenceId)/user_pinned?value=\(userPinned)")
            guard result != nil else { return }

            DispatchQueue.main.sync {
                let latestSequenceUpdated: ChatSequence? = self.loadedChatSequences[sequenceId]?
                    .replaceUserPinned(pinned: userPinned)
                if latestSequenceUpdated != nil {
                    self.updateSequence(withSameId: latestSequenceUpdated!)
                }
            }
        }
    }

    // MARK: - ChatSequence change members
    override public func fetchRecents(
        lookback: TimeInterval?,
        limit: Int?,
        includeUserPinned: Bool?,
        includeLeafSequences: Bool?,
        includeAll: Bool?
    ) async throws {
        return try await doFetchRecents(
            lookback: lookback,
            limit: limit,
            includeUserPinned: includeUserPinned,
            includeLeafSequences: includeLeafSequences,
            includeAll: includeAll
        )
    }

    // Limiter to avoid spamming requests at the server
    // TODO: Figure out why things like alt-tab wind up spamming this endpoint 12/24 times
    var blockFetchRecentsUntil: Date = Date.distantPast

    // MARK: - ChatSequence continue
    override public func sequenceContinue(_ params: ContinueParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        return await doSequenceContinue(params)
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
        print("[TRACE] Sending POST \(endpoint) <= \(httpBody?.count ?? 0) bytes")
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
