import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService
    @State private var jobsService: JobsManagerService

    init() {
        self.chatService = ChatSyncService()
        self.jobsService = JobsManagerService()
    }

    var body: some Scene {
        WindowGroup {
            AppSidebarView()
                .environment(chatService)
                .environment(jobsService)
        }
    }
}
