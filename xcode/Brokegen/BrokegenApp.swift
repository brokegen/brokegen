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
    @State private var jobsService: JobsManagerService = DefaultJobsManagerService(
        startServicesImmediately: UserDefaults.standard.bool(forKey: "startServicesImmediately"),
        allowExternalTraffic: UserDefaults.standard.bool(forKey: "allowExternalTraffic"))
    @State private var providerService: ProviderService = DefaultProviderService(serverBaseURL, configuration: configuration)

    @ObservedObject private var appSettings = AppSettings()
    @State private var inferenceSettingsUpdater: AnyCancellable? = nil
    @ObservedObject private var chatSettingsService = CSCSettingsService()

    @Environment(\.openWindow) var openWindow

    init() {
        // Do on-startup init, because otherwise we store no data and app is empty
        if UserDefaults.standard.bool(forKey: "startServicesImmediately") {
            callInitializers()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [self] _ in
            // Terminate Jobs on exit
            jobsService.terminateAll()
        }
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

    func resetAllUserSettings() {
        DispatchQueue.main.async {
            UserDefaults.resetStandardUserDefaults()
            // This is needed for any HTTP 301's we left lying around during testing.
            URLCache.shared.removeAllCachedResponses()

            chatService.chatSequenceClientModels = []
            chatService.loadedChatSequences = []

            providerService.allModels = []
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
                NavigationLink(destination: EmptyView()) {
                    Text("New Chat")
                }
                .keyboardShortcut("n", modifiers: [.command])
                // Disabled, because can't figure out what View hierarchy would pass the @Environments
                .disabled(true)
            }

            CommandGroup(after: .toolbar) {
                // Basically the same as SidebarCommands(), but with different shortcut
                Button(action: {
                    NSApp.keyWindow?.contentViewController?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        with: nil)
                }, label: {
                    Text("Toggle Sidebar")
                })
                .keyboardShortcut("\\", modifiers: [.command])
            }

            CommandMenu("Settings", content: {
                Toggle(isOn: $appSettings.showDebugSidebarItems) {
                    Text("Show debug sidebar items")
                }

                Button(action: resetAllUserSettings, label: {
                    Label("Reset all user settings", systemImage: "exclamationmark.fill")
                })

                Divider()

                Toggle(isOn: $appSettings.startServicesImmediately, label: {
                    Text("Start brokegen/ollama services on app startup")
                })

                Toggle(isOn: $appSettings.allowExternalTraffic, label: {
                    Text("Allow non-localhost traffic\n(applies at next service launch)")
                })

                Toggle(isOn: $chatSettingsService.useSimplifiedSequenceViews) {
                    Text("Use simplified chat interface")
                }
            })
        }
    }
}
