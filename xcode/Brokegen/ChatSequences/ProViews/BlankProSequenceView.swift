import SwiftUI

/// TODO: Class is busted. Every time you send a follow-up message, it's based on the original sequenceId.
struct BlankProSequenceView: View {
    let chatService: ChatSyncService
    let chatSettingsService: CSCSettingsService
    @Environment(PathHost.self) private var pathHost

    @ObservedObject var viewModel: OneSequenceViewModel

    static func createBlank(chatService: ChatSyncService, appSettings: AppSettings, chatSettingsService: CSCSettingsService) -> OneSequenceViewModel {
        let sequence = ChatSequence(
            serverId: nil,
            messages: [
                .legacy(Message(role: "placeholder", content: "", createdAt: nil)),
            ]
        )

        let settings = CSCSettingsService.SettingsProxy(
            defaults: chatSettingsService.defaults,
            override: OverrideCSUISettings(),
            inference: CSInferenceSettings()
        )

        return OneSequenceViewModel(sequence: sequence, chatService: chatService, settings: settings, chatSettingsService: chatSettingsService, appSettings: appSettings)
    }

    init(chatService: ChatSyncService, appSettings: AppSettings, chatSettingsService: CSCSettingsService) {
        self.chatService = chatService
        self.chatSettingsService = chatSettingsService
        
        self.viewModel = BlankProSequenceView.createBlank(chatService: chatService, appSettings: appSettings, chatSettingsService: chatSettingsService)
    }

    var body: some View {
        ProSequenceView(viewModel)
        // As soon as we have a committed ChatSequenceServerID,
        // commit the ViewModel to ChatSyncService.
            .onChange(of: viewModel.sequence.serverId) {
                chatService.updateSequence(withSameId: viewModel.sequence)
                let maybeNewViewModel: OneSequenceViewModel = chatService.addClientModel(viewModel)

                // Manually reach into CSCSettingsService and update it with the Settings we'd created in createBlank()
                self.chatSettingsService.perSequenceUiSettings[maybeNewViewModel.sequence] = maybeNewViewModel.settings.override
                self.chatSettingsService.perSequenceInferenceSettings[maybeNewViewModel.sequence] = maybeNewViewModel.settings.inference

                pathHost.push(maybeNewViewModel)
            }
    }
}
