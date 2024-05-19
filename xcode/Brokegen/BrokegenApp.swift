import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var jobsService: JobsManagerService

    init() {
        self.jobsService = JobsManagerService()
    }

    var body: some Scene {
        WindowGroup {
            LLMSidebarView()
                .environment(jobsService)
        }
    }
}
