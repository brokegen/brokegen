import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService = ChatSyncService()
    @State private var jobsService: JobsManagerService
    @State private var providerService: ProviderService = ProviderService()
    @State private var inferenceModelSettings: InferenceModelSettings

    init() {
        self.jobsService = DefaultJobsManagerService()
        self.inferenceModelSettings = InferenceModelSettings()
    }

    var body: some Scene {
        WindowGroup(for: UUID.self) { _ in
            BrokegenAppView()
                .environment(chatService)
                .environment(jobsService)
                .environment(providerService)
                .environment(inferenceModelSettings)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
