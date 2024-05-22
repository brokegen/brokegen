import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService
    @State private var jobsService: JobsManagerService

    init() {
        self.chatService = ChatSyncService()
        self.jobsService = JobsManagerService()

        for n in 1...15 {
            self.chatService.fetchMessage(id: n)
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environment(chatService)
                .environment(jobsService)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
