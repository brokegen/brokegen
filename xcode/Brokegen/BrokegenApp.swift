import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService
    @State private var jobsService: JobsManagerService
    @State private var providerService: ProviderService

    init() {
        self.chatService = ChatSyncService()
        self.jobsService = JobsManagerService()
        self.providerService = ProviderService()

        for n in 1...15 {
            self.chatService.fetchMessage(id: n)
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environment(chatService)
                .environment(jobsService)
                .environment(providerService)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
