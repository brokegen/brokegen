import Combine
import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService = ChatSyncService()
    @State private var jobsService: JobsManagerService = DefaultJobsManagerService()
    @State private var providerService: ProviderService = ProviderService()

    private var settingsService = SettingsService()
    @State private var inferenceModelSettingsUpdater: AnyCancellable? = nil

    init() {
        // Do on-startup init, because otherwise we store no data and app is empty
        callInitializers()
    }

    func callInitializers() {
        inferenceModelSettingsUpdater = providerService.$allModels.sink { _ in
            settingsService.inflateModels(providerService)
        }

        Task {
            _ = try? await providerService.fetchAllProviders()
            await providerService.fetchAvailableModels()
            settingsService.inflateModels(providerService)
        }
    }

    var body: some Scene {
        WindowGroup(for: UUID.self) { _ in
            BrokegenAppView()
                .environment(chatService)
                .environment(jobsService)
                .environment(providerService)
                .environment(settingsService.inferenceModelSettings)
                .environment(settingsService.sequenceSettings)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
