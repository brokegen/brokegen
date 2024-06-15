import Combine
import Foundation
import SwiftUI

let serverBaseURL: String = "http://127.0.0.1:6635"
let configuration: URLSessionConfiguration = { slowTimeouts in
    // Keep the timeout to 2 seconds, because we virtually require the embedded server to be up.
    // For slow/loaded systems, or if a debugger is attached, we should bump this number.
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = slowTimeouts ? 24 * 3600.0 : 5.0
    configuration.timeoutIntervalForResource = 7 * 24 * 3600.0

    return configuration
}(true)

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService = DefaultChatSyncService(serverBaseURL, configuration: configuration)
    @State private var jobsService: JobsManagerService = DefaultJobsManagerService()
    @State private var providerService: ProviderService = DefaultProviderService(serverBaseURL, configuration: configuration)

    private var inferenceSettings = InferenceSettingsService()
    @State private var inferenceSettingsUpdater: AnyCancellable? = nil
    @ObservedObject private var chatSettingsService = CSCSettingsService()

    init() {
        // Do on-startup init, because otherwise we store no data and app is empty
        callInitializers()
    }

    func callInitializers() {
        inferenceSettingsUpdater = providerService.$allModels.sink { _ in
            inferenceSettings.inflateModels(providerService)
        }

        Task {
            do { _ = try await providerService.fetchAllProviders() }
            catch { print("[ERROR] Failed to providerService.fetchAllProviders()") }

            do { try await providerService.fetchAvailableModels() }
            catch { print("[ERROR] Failed to providerService.fetchAvailableModels()") }

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
                .environmentObject(chatSettingsService)
                .onReceive(chatSettingsService.objectWillChange) { entireService in
                    print("[TRACE] useSimplifiedSequenceView: \(chatSettingsService.useSimplifiedSequenceViews)")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                NavigationLink(destination: EmptyView(), label: {
                    Text("New Chat")
                })
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(true)
            }

            CommandGroup(after: .sidebar) {
                Button(action: {
                }, label: {
                    Text("Toggle Sidebar")
                })
                .disabled(true)
            }

            CommandMenu("Generation", content: {
                HStack {
                    Image(systemName: "gear")
                    Text("gear")
                        .font(.system(size: 32))
                }
                VStack {
                    Text("yeah")
                    Divider()
                }
            })
        }
    }
}
