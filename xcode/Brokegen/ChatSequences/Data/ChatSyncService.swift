import Alamofire
import Combine
import Foundation
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
        for sequence: ChatSequence
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
    var loadedChatSequences: [ChatSequenceServerID : ChatSequence] = [:]

    public func constructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID? {
        return nil
    }

    public func constructNewChatSequence(messageId: ChatMessageServerID, humanDesc: String = "") async throws -> ChatSequenceServerID? {
        return nil
    }

    public func appendMessage(sequence: ChatSequence, messageId: ChatMessageServerID) async throws -> ChatSequenceServerID? {
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

    func renameChatSequence(_ sequence: ChatSequence, to newHumanDesc: String?) async -> ChatSequence? {
        guard newHumanDesc != sequence.humanDesc else { return nil }
        return sequence.replaceHumanDesc(desc: newHumanDesc)
    }

    func pinChatSequence(
        _ sequence: ChatSequence,
        pinned userPinned: Bool
    ) {
        guard userPinned != sequence.userPinned else { return }

        let updatedSequence = sequence.replaceUserPinned(pinned: userPinned)
        self.updateSequence(withSameId: updatedSequence)
    }

    // MARK: - ChatSequence change members
    public func fetchRecents(lookback: TimeInterval? = nil, limit: Int? = nil, onlyUserPinned: Bool? = nil) async throws {
    }

    func updateSequence(withSameId updatedSequence: ChatSequence, disablePublish: Bool = false) {
        // Keep the first ChatSequence's clientId, in case of duplicates
        let originalClientId: UUID? = loadedChatSequences[updatedSequence.serverId]?.id
        if originalClientId != nil {
            loadedChatSequences[updatedSequence.serverId] = updatedSequence.replaceId(originalClientId!)
        }
        else {
            loadedChatSequences[updatedSequence.serverId] = updatedSequence
        }

        // Update matching client models that held the original sequence
        let matchingClientModels = chatSequenceClientModels.filter {
            $0.sequence.serverId == updatedSequence.serverId
        }

        for clientModel in matchingClientModels {
            clientModel.sequence = updatedSequence
        }

        if !disablePublish {
            // Without this, SwiftUI won't notice renames in particular.
            // Possibly because we're keeping the Identifiable .id the same?
            objectWillChange.send()
        }
    }

    func updateSequenceOffline(_ originalSequenceId: ChatSequenceServerID, withReplacement updatedSequence: ChatSequence) {
        // Keep the first ChatSequence's clientId, in case of duplicates
        let originalClientId: UUID? = loadedChatSequences[updatedSequence.serverId]?.id
        if originalClientId != nil {
            loadedChatSequences[updatedSequence.serverId] = updatedSequence.replaceId(originalClientId!)
        }
        else {
            loadedChatSequences[updatedSequence.serverId] = updatedSequence
        }

        // Update any clientModels that might hold it
        let matchingClientModels: [OneSequenceViewModel] = chatSequenceClientModels.filter {
            $0.sequence.serverId == originalSequenceId
        }

        for clientModel in matchingClientModels {
            clientModel.sequence = updatedSequence
        }

        objectWillChange.send()
    }

    // MARK: - ChatSequence continue
    public func sequenceContinue(_ params: ChatSequenceParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        let error: AFError = AFError.sessionTaskFailed(error: ChatSyncServiceError.callingAbstractBaseMethod)
        return Fail(error: AFErrorAndData(error: error, data: nil))
            .eraseToAnyPublisher()
    }
}
