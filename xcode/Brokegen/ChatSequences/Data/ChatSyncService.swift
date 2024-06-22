import Alamofire
import Combine
import Foundation
import SwiftUI

typealias ChatMessageServerID = Int

enum ChatMessageError: Error {
    case expectedUserRole
    case failedDateDecoding
}

enum ChatSyncServiceError: Error {
    case emptyRequestContent
    case noResponseContentReturned
    case invalidResponseContentReturned
    case invalidResponseStatusCode(_ errorCode: Int)
    case callingAbstractBaseMethod
}

/// TODO: Limit scope of ObservableObject to the loadedChatSequences, and see if background refresh improves
/// (right now the entire app gets choppy).
class ChatSyncService: Observable, ObservableObject {
    /// Used to check when the @Environment was injected correctly;
    /// NavigationStack's Views aren't children of each other, so they have to be re-injected.
    public func ping() {
        print("[TRACE] ChatSyncService ping at \(Date.now)")
    }

    // MARK: - Client side models
    var chatSequenceClientModels: [OneSequenceViewModel] = []

    public func clientModel(for sequence: ChatSequence, appSettings: AppSettings, chatSettingsService: CSCSettingsService) -> OneSequenceViewModel {
        if let existingSeq = chatSequenceClientModels.first(where: {
            $0.sequence == sequence
        }) {
            return existingSeq
        }
        else {
            let newModel = OneSequenceViewModel(sequence, chatService: self, appSettings: appSettings, chatSettingsService: chatSettingsService)
            chatSequenceClientModels.append(newModel)
            return newModel
        }
    }

    // MARK: - ChatSequence construction
    @Published var loadedChatSequences: [ChatSequence] = []

    public func constructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID? {
        return nil
    }

    public func constructNewChatSequence(messageId: ChatMessageServerID, humanDesc: String = "") async throws -> ChatSequenceServerID? {
        return nil
    }

    public func fetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        return nil
    }

    func renameChatSequence(_ sequence: ChatSequence, to newHumanDesc: String?) -> ChatSequence {
        return sequence.replaceHumanDesc(desc: newHumanDesc)
    }

    func pinChatSequence(
        _ sequence: ChatSequence,
        pinned userPinned: Bool
    ) -> ChatSequence {
        guard userPinned != sequence.userPinned else { return sequence }
        return sequence.replaceUserPinned(pinned: userPinned)
    }

    // MARK: - ChatSequence change members
    public func fetchRecents(lookback: TimeInterval? = nil, limit: Int? = nil, onlyUserPinned: Bool? = nil) async throws {
    }

    func updateSequence(withSameId updatedSequence: ChatSequence) {
        // Keep the first ChatSequence's clientId, in case of duplicates
        var originalClientId: UUID? = nil

        if let removalIndex = loadedChatSequences.firstIndex(where: {
            $0.serverId == updatedSequence.serverId
        }) {
            originalClientId = loadedChatSequences[removalIndex].id
        }

        // Remove all matching ChatSequences
        loadedChatSequences.removeAll(where: {
            $0.serverId == updatedSequence.serverId
        })

        if let clientId = originalClientId {
            loadedChatSequences.insert(updatedSequence.replaceId(clientId), at: 0)
        }
        else {
            loadedChatSequences.insert(updatedSequence, at: 0)
        }

        let staticSequenceId = updatedSequence.serverId
        let predicate = #Predicate<OneSequenceViewModel> {
            $0.sequence.serverId == staticSequenceId
        }

        do {
            for clientModel in try chatSequenceClientModels.filter(predicate) {
                clientModel.sequence = updatedSequence
            }
        }
        catch {}
    }

    func updateSequence(_ originalSequenceId: ChatSequenceServerID?, withNewSequence updatedSequenceId: ChatSequenceServerID) async -> ChatSequence? {
        return nil
    }

    // MARK: - ChatSequence extend/continue
    public func sequenceContinue(_ params: ChatSequenceParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        let error: AFError = AFError.sessionTaskFailed(error: ChatSyncServiceError.callingAbstractBaseMethod)
        return Fail(error: AFErrorAndData(error: error, data: nil))
            .eraseToAnyPublisher()
    }

    public func sequenceExtend(_ params: ChatSequenceParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        let error: AFError = AFError.sessionTaskFailed(error: ChatSyncServiceError.callingAbstractBaseMethod)
        return Fail(error: AFErrorAndData(error: error, data: nil))
            .eraseToAnyPublisher()
    }
}

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

    override public func fetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        return try await doFetchChatSequenceDetails(sequenceId)
    }

    override func renameChatSequence(_ sequence: ChatSequence, to newHumanDesc: String?) -> ChatSequence {
        return sequence.replaceHumanDesc(desc: newHumanDesc)
    }

    override func pinChatSequence(
        _ sequence: ChatSequence,
        pinned userPinned: Bool
    ) -> ChatSequence {
        guard userPinned != sequence.userPinned else { return sequence }
        // Start this in a Task because we don't much care what it returns.
        Task {
            try? await self.postDataBlocking(nil, endpoint: "/sequences/\(sequence.serverId!)/user_pinned?value=\(userPinned)")
        }

        return sequence.replaceUserPinned(pinned: userPinned)
    }

    // MARK: - ChatSequence change members
    override public func fetchRecents(lookback: TimeInterval?, limit: Int?, onlyUserPinned: Bool?) async throws {
        return try await doFetchRecents(lookback: lookback, limit: limit, onlyUserPinned: onlyUserPinned)
    }

    override func updateSequence(_ originalSequenceId: ChatSequenceServerID?, withNewSequence updatedSequenceId: ChatSequenceServerID) async -> ChatSequence? {
        return await doUpdateSequence(originalSequenceId: originalSequenceId, updatedSequenceId: updatedSequenceId)
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
        var responseStatusCode: Int? = nil

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
            .response { r in
                switch r.result {
                case .success(let data):
                    if responseStatusCode != nil {
                        print("[TRACE] \(self.serverBaseURL + endpoint) returned HTTP \(responseStatusCode!)")
                        // If it's in the 400 range, don't do the continuation; we'll follow the redirect
                        if (300..<400).contains(responseStatusCode!) {
                            return
                        }
                        else if (200..<300).contains(responseStatusCode!) {
                            // Do nothing, fall through to below handlers
                        }
                        else {
                            // If the HTTP code is super invalid, throw an error
                            continuation.resume(throwing: ChatSyncServiceError.invalidResponseStatusCode(responseStatusCode!))
                        }
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
        var responseStatusCode: Int? = nil

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
            .response { r in
                switch r.result {
                case .success(let data):
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        print("[DEBUG] \(endpoint) returned HTTP \(responseStatusCode!)")
                        continuation.resume(throwing: ChatSyncServiceError.invalidResponseStatusCode(responseStatusCode!))
                    }

                    if data != nil {
                        print("[DEBUG] \(endpoint) returned \(String(describing: data))")
                        continuation.resume(returning: data!)
                    }
                    else {
                        print("[DEBUG] \(endpoint) returned no data")
                        continuation.resume(throwing: ChatSyncServiceError.noResponseContentReturned)
                    }

                case .failure(let error):
                    print("[DEBUG] \(endpoint) failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func postDataAsJson(_ httpBody: Data?, endpoint: String) async throws -> [String : Any]? {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                serverBaseURL + endpoint
            ) { urlRequest in
                urlRequest.method = .post
                urlRequest.headers = [
                    "Content-Type": "application/json"
                ]
                urlRequest.httpBody = httpBody
            }
            .response { r in
                switch r.result {
                case .success(let data):
                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data!, options: []) as! [String : Any]
                        print("POST \(endpoint): \(jsonDict)")
                        continuation.resume(returning: jsonDict)
                    }
                    catch {
                        print("POST \(endpoint) decoding failed: \(String(describing: data))")
                        continuation.resume(returning: nil)
                    }
                case .failure(let error):
                    print("POST \(endpoint) failed: " + error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
