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
    @State private var jobsService: JobsManagerService
    @State private var providerService: ProviderService = DefaultProviderService(serverBaseURL, configuration: configuration)

    private var appSettings = AppSettings()
    @State private var inferenceSettingsUpdater: AnyCancellable? = nil
    @ObservedObject private var chatSettingsService = CSCSettingsService()

    @Environment(\.openWindow) var openWindow

    init() {
        _jobsService = State(initialValue: DefaultJobsManagerService(startServicesImmediately: false, allowExternalTraffic: UserDefaults.standard.bool(forKey: "allowExternalTraffic")))
        // Do on-startup init, because otherwise we store no data and app is empty
        callInitializers()
    }

    func callInitializers() {
        Task {
            do { _ = try await providerService.fetchAllProviders() }
            catch { print("[ERROR] Failed to providerService.fetchAllProviders()") }

            do { try await providerService.fetchAvailableModels() }
            catch { print("[ERROR] Failed to providerService.fetchAvailableModels()") }

            appSettings.link(to: providerService)
        }
    }

    var body: some Scene {
        WindowGroup(id: "8280", for: UUID.self) { _ in
            BrokegenAppView()
                .environment(chatService)
                .environment(jobsService)
                .environment(providerService)
                .environmentObject(appSettings)
                .environmentObject(chatSettingsService)
                .onReceive(chatSettingsService.objectWillChange) { entireService in
                    print("[TRACE] useSimplifiedSequenceView: \(chatSettingsService.useSimplifiedSequenceViews)")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(action: {
                    openWindow(id: "8280")
                }, label: {
                    Text("New Window")
                })
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                NavigationLink(destination: BlankOneSequenceView()) {
                    Text("New Chat")
                }
                .keyboardShortcut("n", modifiers: [.command])
                // Disabled, because can't figure out what View hierarchy would pass the @Environments
                .disabled(true)
            }

            CommandGroup(after: .appSettings) {
                Toggle(isOn: $chatSettingsService.useSimplifiedSequenceViews) {
                    Text("Use simplified chat interface")
                }
            }

            CommandMenu("Generation", content: {
                HStack {
                    Image(systemName: "gear")
                    Text("gear")
                        .font(.system(size: 64))
                }
                VStack {
                    Text("yeah")
                    Divider()
                }
            })
        }
    }
}
