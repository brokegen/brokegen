import Combine
import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService = ChatSyncService()
    @State private var jobsService: JobsManagerService = DefaultJobsManagerService()
    @State private var providerService: ProviderService = ProviderService()

    private var inferenceSettings = InferenceSettingsService()
    @State private var inferenceSettingsUpdater: AnyCancellable? = nil
    private var chatSettingsService = CSCSettingsService()

    init() {
        // Do on-startup init, because otherwise we store no data and app is empty
        callInitializers()
    }

    func callInitializers() {
        inferenceSettingsUpdater = providerService.$allModels.sink { _ in
            inferenceSettings.inflateModels(providerService)
        }

        Task {
            _ = try? await providerService.fetchAllProviders()
            await providerService.fetchAvailableModels()
            inferenceSettings.inflateModels(providerService)
        }
    }

    var body: some Scene {
        WindowGroup(for: UUID.self) { _ in
            BrokegenAppView()
                .environment(chatService)
                .environment(jobsService)
                .environment(providerService)
                .environment(inferenceSettings.inferenceModelSettings)
                .environment(chatSettingsService.sequenceSettings)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
