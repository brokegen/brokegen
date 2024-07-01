import Alamofire
import Combine
import Foundation
import SwiftUI
import SwiftyJSON

typealias ChatMessageServerID = Int

enum ChatMessageError: Error {
    case expectedUserRole
    case failedDateDecoding
}

enum ChatSyncServiceError: Error {
    case emptyRequestContent
    case noResponseContentReturned
    case invalidResponseContentReturned
    case invalidResponseStatusCode(_ errorCode: Int, data: Data?)
    case callingAbstractBaseMethod
}

@Observable
class ChatSyncService: ObservableObject {
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

    func addClientModel(_ clientModel: OneSequenceViewModel) -> OneSequenceViewModel {
        if let dupe = chatSequenceClientModels.first(where: { $0 == clientModel }) {
            return clientModel
        }
        if let dupe = chatSequenceClientModels.first(where: { $0.sequence == clientModel.sequence }) {
            print("[ERROR] ChatSyncService already contains another ViewModel for ChatSequence \(dupe.sequence.displayRecognizableDesc())")
            return dupe
        }
        if let dupe = chatSequenceClientModels.first(where: { $0.sequence.serverId == clientModel.sequence.serverId }) {
            print("[ERROR] ChatSyncService already contains another ViewModel for ChatSequenceID \(dupe.sequence.serverId)")
            return dupe
        }

        // After some duplicate-checking, we're good to go ahead and add the model.
        chatSequenceClientModels.append(clientModel)
        return clientModel
    }

    func addClientModel(
        fromBlank blankModel: BlankSequenceViewModel,
        for sequence: ChatSequence,
        withRetrieval: Bool
    ) -> OneSequenceViewModel {
        let model: OneSequenceViewModel = OneSequenceViewModel(sequence, chatService: blankModel.chatService, appSettings: blankModel.appSettings, chatSettingsService: blankModel.chatSettingsService)
        model.submitting = blankModel.submitting
        model.submittedAssistantResponseSeed = blankModel.submittedAssistantResponseSeed
        model.serverStatus = blankModel.serverStatus

        model.showTextEntryView = blankModel.showTextEntryView
        model.showUiOptions = blankModel.showUiOptions
        model.showInferenceOptions = blankModel.showInferenceOptions
        model.showRetrievalOptions = blankModel.showRetrievalOptions
        model.continuationInferenceModel = blankModel.continuationInferenceModel
        model.showAssistantResponseSeed = blankModel.showAssistantResponseSeed
        model.showSystemPromptOverride = blankModel.showSystemPromptOverride

        if let dupe = chatSequenceClientModels.first(where: { $0 == model }) {
            return model
        }
        if let dupe = chatSequenceClientModels.first(where: { $0.sequence == model.sequence }) {
            print("[ERROR] ChatSyncService already contains another ViewModel for ChatSequence \(dupe.sequence.displayRecognizableDesc())")
            return dupe
        }
        if let dupe = chatSequenceClientModels.first(where: { $0.sequence.serverId == model.sequence.serverId }) {
            print("[ERROR] ChatSyncService already contains another ViewModel for ChatSequenceID \(dupe.sequence.serverId)")
            return dupe
        }

        // After some duplicate-checking, we're good to go ahead and add the model.
        chatSequenceClientModels.append(model)
        return model
    }

    // MARK: - ChatSequence construction
    var loadedChatSequences: [ChatSequence] = []

    public func constructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID? {
        return nil
    }

    public func constructNewChatSequence(messageId: ChatMessageServerID, humanDesc: String = "") async throws -> ChatSequenceServerID? {
        return nil
    }

    public func fetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        return nil
    }

    func autonameChatSequence(_ sequence: ChatSequence, preferredAutonamingModel: FoundationModelRecordID?) -> String? {
        if let result = Optional("[mock client-side autoname]") {
            let autonamedSequence = sequence.replaceHumanDesc(desc: result)
            self.updateSequence(withSameId: autonamedSequence)
            return result
        }
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

        // Without this, SwiftUI won't notice renames in particular.
        // Possibly because we're keeping the Identifiable .id the same?
        objectWillChange.send()
    }

    func updateSequence(_ originalSequenceId: ChatSequenceServerID?, withNewSequence updatedSequenceId: ChatSequenceServerID) async -> ChatSequence? {
        return nil
    }

    func updateSequenceOffline(_ originalSequenceID: ChatSequenceServerID?, withReplacement updatedSequence: ChatSequence) {
        print("[DEBUG] Attempting to update \(originalSequenceID) to new_sequence_id: \(updatedSequence.serverId)")

        // Remove all matching ChatSequences
        loadedChatSequences.removeAll(where: {
            $0.serverId == originalSequenceID
        })

        // Add the replacement
        loadedChatSequences.insert(updatedSequence, at: 0)

        // Update any clientModels that might hold it
        let matchingClientModels: [OneSequenceViewModel] = chatSequenceClientModels.filter {
            $0.sequence.serverId == originalSequenceID
        }

        for clientModel in matchingClientModels {
            clientModel.sequence = updatedSequence
        }
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

    override func autonameChatSequence(_ sequence: ChatSequence, preferredAutonamingModel: FoundationModelRecordID?) -> String? {
        Task {
            var endpointBuilder = "/sequences/\(sequence.serverId!)/autoname?wait_for_response=true"
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

    override func renameChatSequence(_ sequence: ChatSequence, to newHumanDesc: String?) -> ChatSequence {
        // TODO: Make this synchronous, otherwise failures get eaten
        Task {
            _ = try? await self.postDataBlocking(
                nil,
                endpoint: "/sequences/\(sequence.serverId!)/human_desc?value=\(newHumanDesc ?? "")")
        }

        return sequence.replaceHumanDesc(desc: newHumanDesc)
    }

    override func pinChatSequence(
        _ sequence: ChatSequence,
        pinned userPinned: Bool
    ) -> ChatSequence {
        guard userPinned != sequence.userPinned else { return sequence }

        // TODO: Figure out how to try and make this synchronous, because otherwise failures still result in client updates.
        // For now, this succeeds most of the time, but _silently_.
        Task {
            _ = try? await self.postDataBlocking(
                nil,
                endpoint: "/sequences/\(sequence.serverId!)/user_pinned?value=\(userPinned)")
        }

        return sequence.replaceUserPinned(pinned: userPinned)
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
        print("[TRACE] GET \(endpoint)")
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
