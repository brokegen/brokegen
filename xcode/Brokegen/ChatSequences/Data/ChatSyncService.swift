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
        from clientModel: OneSequenceViewModel,
        for sequence: ChatSequence
    ) -> OneSequenceViewModel {
        let newClientModel = OneSequenceViewModel(
            sequence: sequence,
            chatService: clientModel.chatService,
            // TODO: Confirm that these values are actually cloned, and won't impact the previous clientModel.
            settings: CSCSettingsService.SettingsProxy(
                defaults: clientModel.settings.defaults,
                override: clientModel.settings.override,
                inference: clientModel.settings.inference),
            chatSettingsService: clientModel.chatSettingsService,
            appSettings: clientModel.appSettings
        )
        // Modify the branched client model so it clones our current settings.
        newClientModel.promptInEdit = clientModel.promptInEdit
        newClientModel.showTextEntryView = clientModel.showTextEntryView
        newClientModel.showUiOptions = clientModel.showUiOptions
        newClientModel.showInferenceOptions = clientModel.showInferenceOptions
        newClientModel.showRetrievalOptions = clientModel.showRetrievalOptions
        newClientModel.continuationInferenceModel = clientModel.continuationInferenceModel
        newClientModel.showAssistantResponseSeed = clientModel.showAssistantResponseSeed
        newClientModel.showSystemPromptOverride = clientModel.showSystemPromptOverride

        return self.addClientModel(newClientModel)
    }

    func addClientModel(
        fromBlank blankModel: BlankSequenceViewModel,
        for sequence: ChatSequence
    ) -> OneSequenceViewModel {
        let model: OneSequenceViewModel = OneSequenceViewModel(sequence, chatService: blankModel.chatService, appSettings: blankModel.appSettings, chatSettingsService: blankModel.chatSettingsService)
        model.submitting = blankModel.submitting
        model.submittedAssistantResponseSeed = blankModel.submittedAssistantResponseSeed
        model.serverStatus = blankModel.serverStatus

        model.promptInEdit = blankModel.promptInEdit
        model.showTextEntryView = blankModel.showTextEntryView
        model.showUiOptions = blankModel.showUiOptions
        model.showInferenceOptions = blankModel.showInferenceOptions
        model.showRetrievalOptions = blankModel.showRetrievalOptions
        model.continuationInferenceModel = blankModel.continuationInferenceModel
        model.showAssistantResponseSeed = blankModel.showAssistantResponseSeed
        model.showSystemPromptOverride = blankModel.showSystemPromptOverride

        return self.addClientModel(model)
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

    func autonameBlocking(sequenceId: ChatSequenceServerID, preferredAutonamingModel: FoundationModelRecordID?) async throws -> String? {
        let sequence: ChatSequence? = loadedChatSequences[sequenceId]
        guard sequence != nil else { return nil }

        if let result = Optional("[mock client-side autoname]") {
            let autonamedSequence = sequence!.replaceHumanDesc(desc: result)
            await self.updateSequenceBlocking(withSameId: autonamedSequence)
            return result
        }
        return nil
    }

    func renameBlocking(sequenceId: ChatSequenceServerID, to newHumanDesc: String?) async throws -> ChatSequence? {
        let sequence: ChatSequence? = loadedChatSequences[sequenceId]
        guard sequence != nil else { return nil }
        guard newHumanDesc != sequence!.humanDesc else { return nil }

        let updatedSequence = sequence!.replaceHumanDesc(desc: newHumanDesc)
        await self.updateSequenceBlocking(withSameId: updatedSequence)
        return updatedSequence
    }

    func pin(
        sequenceId: ChatSequenceServerID,
        pinned userPinned: Bool
    ) {
        let sequence: ChatSequence? = loadedChatSequences[sequenceId]
        guard sequence != nil else { return }
        guard userPinned != sequence!.userPinned else { return }

        let updatedSequence = sequence!.replaceUserPinned(pinned: userPinned)
        self.updateSequence(withSameId: updatedSequence)
    }

    // MARK: - ChatSequence change members
    public func fetchRecents(
        lookback: TimeInterval? = nil,
        limit: Int? = nil,
        includeUserPinned: Bool?,
        includeLeafSequences: Bool?,
        includeAll: Bool?
    ) async throws {
    }

    @MainActor func updateSequenceBlocking(withSameId updatedSequence: ChatSequence, disablePublish: Bool = false) {
        loadedChatSequences[updatedSequence.serverId] = updatedSequence

        // Update matching client models that held the original sequence,
        // but ONLY if it's not currently undergoing a refresh.
        let matchingClientModels = chatSequenceClientModels.filter {
            $0.sequence.serverId == updatedSequence.serverId
        }

        for clientModel in matchingClientModels {
            if clientModel.receiving {
                print("[INFO] clientModel for \(updatedSequence) is still updating, will ignore incoming JSON model data")
            }
            else {
                clientModel.sequence = updatedSequence
            }
        }

        if !disablePublish {
            objectWillChange.send()
        }
    }

    func updateSequence(withSameId updatedSequence: ChatSequence, disablePublish: Bool = false) {
        loadedChatSequences[updatedSequence.serverId] = updatedSequence

        // Update matching client models that held the original sequence,
        // but ONLY if it's not currently undergoing a refresh.
        let matchingClientModels = chatSequenceClientModels.filter {
            $0.sequence.serverId == updatedSequence.serverId
        }

        for clientModel in matchingClientModels {
            if clientModel.receiving {
                print("[INFO] clientModel for \(updatedSequence) is still updating, will ignore incoming JSON model data")
            }
            else {
                clientModel.sequence = updatedSequence
            }
        }

        if !disablePublish {
            objectWillChange.send()
        }
    }

    // TODO: There's a couple potential race conditions happening with the way this is implemented.
    // Multiple ChatSequence updates can happen at once, and only the latest one might get reflected.
    func updateSequenceOffline(_ originalSequenceId: ChatSequenceServerID, withReplacement updatedSequence: ChatSequence) {
        print("[TRACE] ChatSyncService.updateSequenceOffline(\(originalSequenceId), withReplacement: \(updatedSequence.displayServerId()))")
        loadedChatSequences[updatedSequence.serverId] = updatedSequence

        // Update any clientModels that might hold it
        let matchingClientModels: [OneSequenceViewModel] = chatSequenceClientModels.filter {
            $0.sequence.serverId == originalSequenceId
        }

        for clientModel in matchingClientModels {
            clientModel.sequence = updatedSequence
        }

        // TODO: This doesn't broadcast the loadedChatSequences changes correctly.
        objectWillChange.send()
    }

    // MARK: - ChatSequence continue
    public func sequenceContinue(_ params: ContinueParameters) async -> AnyPublisher<Data, AFErrorAndData> {
        let error: AFError = AFError.sessionTaskFailed(error: ChatSyncServiceError.callingAbstractBaseMethod)
        return Fail(error: AFErrorAndData(error: error, data: nil))
            .eraseToAnyPublisher()
    }
}
