import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

@Observable
class BlankSequenceViewModel: ObservableObject {
    let chatService: ChatSyncService
    var settings: CSCSettingsService.SettingsProxy
    let chatSettingsService: CSCSettingsService
    let appSettings: AppSettings

    var humanDesc: String? = nil
    var promptInEdit: String = ""
    var submitting: Bool = false

    @ObservationIgnored var submittedAssistantResponseSeed: String? = nil
    var serverStatus: String? = nil

    private var stayAwake: StayAwake = StayAwake()
    var currentlyAwakeDuringInference: Bool {
        get { stayAwake.assertionIsActive }
    }

    // MARK: - Options and Configurations
    var showTextEntryView: Bool = true
    var showUiOptions: Bool = false
    var showInferenceOptions: Bool = false
    var showRetrievalOptions: Bool = false

    var continuationInferenceModel: FoundationModel? = nil
    var showAssistantResponseSeed: Bool = false
    var showSystemPromptOverride: Bool = false

    init(
        chatService: ChatSyncService,
        settings: CSCSettingsService.SettingsProxy,
        chatSettingsService: CSCSettingsService,
        appSettings: AppSettings
    ) {
        self.chatService = chatService
        self.settings = settings
        self.chatSettingsService = chatSettingsService
        self.appSettings = appSettings
    }

    var displayHumanDesc: String {
        if humanDesc == nil || humanDesc!.isEmpty {
            return "[draft]"
        }

        return humanDesc!
    }

    var displayServerStatus: String? {
        get {
            if serverStatus == nil || serverStatus!.isEmpty {
                return nil
            }

            return serverStatus
        }
    }

    func requestStart() async -> ChatSequence? {
        print("[INFO] BlankSequenceViewModel.requestStart()")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen BlankSequenceViewModel.requestStart()")
        }

        guard submitting == false else {
            print("[ERROR] BlankSequenceViewModel.requestStart() during another submission")
            return nil
        }

        self.submitting = true
        self.serverStatus = "/sequences/???/continue: preparing request"

        submittedAssistantResponseSeed = settings.seedAssistantResponse

        let messageId: ChatMessageServerID? = try? await chatService.constructChatMessage(from: TemporaryChatMessage(
            role: "user",
            content: promptInEdit,
            createdAt: Date.now
        ))
        guard messageId != nil else {
            submitting = false
            print("[ERROR] Couldn't construct ChatMessage from text: \(promptInEdit)")
            return nil
        }

        let replacementSequenceId: ChatSequenceServerID? = try? await chatService.constructNewChatSequence(messageId: messageId!, humanDesc: humanDesc ?? "")
        guard replacementSequenceId != nil else {
            submitting = false
            print("[ERROR] Couldn't construct sequence from: ChatMessage#\(messageId!)")
            return nil
        }

        // Manually (re)construct server data, rather than fetching the same data back.
        let constructedSequence: ChatSequence = ChatSequence(
            serverId: replacementSequenceId!,
            messages: [
                .stored(ChatMessage(
                    serverId: messageId!,
                    hostSequenceId: replacementSequenceId!,
                    role: "user",
                    content: self.promptInEdit,
                    createdAt: Date.now))
            ]
        )

        submitting = false
        return constructedSequence
    }

    func stopSubmit(userRequested: Bool = false) {
        submitting = false
        serverStatus = nil
    }
}
