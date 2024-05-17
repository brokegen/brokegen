import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var managedProcessService: ManagedProcessService

    init() {
        self._managedProcessService = State(initialValue: ManagedProcessService())
    }

    var body: some Scene {
        WindowGroup {
            LLMSidebarView()
                .environment(managedProcessService)
        }
    }
}
