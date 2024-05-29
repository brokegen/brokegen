import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService
    @State private var jobsService: JobsManagerService
    @State private var providerService: ProviderService
    @State private var pathHost: PathHost = PathHost()

    init() {
        self.chatService = ChatSyncService()
        self.jobsService = JobsManagerService()
        self.providerService = ProviderService()

        for n in 1...10 {
            self.chatService.fetchMessage(id: n)
        }
    }

    var body: some Scene {
        WindowGroup {
            BrokegenAppView(pathHost: $pathHost)
                .environment(chatService)
                .environment(jobsService)
                .environment(providerService)
                .environment(pathHost)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
