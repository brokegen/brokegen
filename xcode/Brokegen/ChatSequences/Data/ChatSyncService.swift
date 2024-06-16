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

    // MARK: - ChatSequence change members
    public func refreshPinnedChatSequences(lookback: TimeInterval? = nil, limit: Int? = nil) async throws {
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

        let predicate = #Predicate<OneSequenceViewModel> {
            $0.sequence.serverId == updatedSequence.serverId
        }
        do {
            for clientModel in try chatSequenceClientModels.filter(predicate) {
                clientModel.sequence = updatedSequence
            }
        }
        catch {}
    }

    func updateSequence(_ originalSequenceId: ChatSequenceServerID?, withNewSequence updatedSequenceId: ChatSequenceServerID) async {
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

    // MARK: - ChatSequence change members
    override public func refreshPinnedChatSequences(lookback: TimeInterval?, limit: Int?) async throws {
        return try await doRefreshPinnedChatSequences(lookback: lookback, limit: limit)
    }

    override func updateSequence(_ originalSequenceId: ChatSequenceServerID?, withNewSequence updatedSequenceId: ChatSequenceServerID) async {
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
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        continuation.resume(throwing: ChatSyncServiceError.invalidResponseStatusCode(responseStatusCode!))
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
                        continuation.resume(throwing: ChatSyncServiceError.invalidResponseStatusCode(responseStatusCode!))
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
