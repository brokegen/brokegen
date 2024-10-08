import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

@Observable
class BlankSequenceViewModel {
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

        resetForNewChat()
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

    func resetForNewChat() {
        // Once we've successfully transferred the info to a different view, clear it out for if the user starts a new chat.
        // Only some settings, though, since most of the other ones tend to get reused.
        humanDesc = nil
        promptInEdit = ""
        submitting = false
        submittedAssistantResponseSeed = nil
        serverStatus = nil
    }

    func requestSave() async -> ChatSequence? {
        print("[INFO] BlankSequenceViewModel.requestSave()")
        if settings.stayAwakeDuringInference {
            // There's only a brief window wherein this is necessary,
            // but it's better to do extra work and ensure user request goes through.
            _ = stayAwake.createAssertion(reason: "brokegen BlankSequenceViewModel.requestSave()")
        }

        guard !submitting else {
            print("[ERROR] BlankSequenceViewModel.requestSave() during another submission, ignoring")
            return nil
        }

        self.submitting = true
        self.serverStatus = "/sequences/???/extend: preparing request"

        submittedAssistantResponseSeed = settings.seedAssistantResponse

        let messageId: ChatMessageServerID? = try? await chatService.constructChatMessage(from: TemporaryChatMessage(
            role: "user",
            content: promptInEdit,
            createdAt: Date.now
        ))
        guard messageId != nil else {
            print("[ERROR] Couldn't construct ChatMessage from text: \(promptInEdit)")
            stopSubmit()
            return nil
        }

        let replacementSequenceId: ChatSequenceServerID? = try? await chatService.constructNewChatSequence(messageId: messageId!, humanDesc: humanDesc ?? "")
        guard replacementSequenceId != nil else {
            print("[ERROR] Couldn't construct sequence from: ChatMessage#\(messageId!)")
            stopSubmit()
            return nil
        }

        // Manually (re)construct server data, rather than fetching the same data back.
        let constructedSequence: ChatSequence = ChatSequence(
            serverId: replacementSequenceId!,
            humanDesc: humanDesc,
            userPinned: false,
            generatedAt: Date.now,
            messages: [
                .serverOnly(ChatMessage(
                    serverId: messageId!,
                    hostSequenceId: replacementSequenceId!,
                    role: "user",
                    content: self.promptInEdit,
                    createdAt: Date.now))
            ],
            isLeafSequence: true,
            parentSequences: [replacementSequenceId!]
        )

        print("[TRACE] BlankSequenceViewModel.requestSave calling updateSequenceOffline: ChatSequence#\(replacementSequenceId!)")
        DispatchQueue.main.sync {
            self.chatService.updateSequenceOffline(replacementSequenceId!, withReplacement: constructedSequence)
        }

        stopSubmit()
        return constructedSequence
    }

    func stopSubmit(userRequested: Bool = false) {
        submitting = false
        serverStatus = nil
    }
}
