import Combine
import Foundation
import SwiftData
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
    private var chatService: ChatSyncService
    @ObservedObject private var jobsService: JobsManagerService
    private var providerService: ProviderService

    private var appSettings: AppSettings
    @State private var inferenceSettingsUpdater: AnyCancellable? = nil
    private var chatSettingsService = CSCSettingsService()

    @Environment(\.openWindow) var openWindow
    @FocusedObject private var windowState: WindowViewModel?
    private var templates: Templates

    @MainActor
    var modelData: ModelContainer = {
        let schema = Schema([
            StoredTextKey.self,
            StoredText.self,
        ])
        do {
            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                return try ModelContainer(
                    for: schema,
                    configurations: [
                        ModelConfiguration(isStoredInMemoryOnly: true)
                    ])
            }
            else {
                let storePath = URL.applicationSupportDirectory
                // We manually append the path component because unsigned apps get special problems.
                    .appendingPathComponent(Bundle.main.bundleIdentifier!)
                    .appending(path: "brokegen.sqlite")

                return try ModelContainer(
                    for: schema,
                    configurations: [
                        ModelConfiguration(schema: schema, url: storePath),
                    ])
            }
        } catch {
            fatalError("[ERROR] Could not create ModelContainer: \(error)")
        }
    }()

    /// We have to make a bunch of "temporary" variables to do a non-automatic init
    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            chatService = ChatSyncService()
            let providerService = ProviderService()
            self.providerService = providerService

            let appSettings = AppSettings()
            self.appSettings = appSettings
            appSettings.link(to: providerService)

            jobsService = JobsManagerService()
        }
        else {
            chatService = DefaultChatSyncService(serverBaseURL, configuration: configuration)
            let providerService = DefaultProviderService(serverBaseURL, configuration: configuration)
            self.providerService = providerService
            providerService.fetchAllProviders(repeatUntilSuccess: true)
            providerService.fetchAvailableModels(repeatUntilSuccess: true)

            let appSettings = AppSettings()
            self.appSettings = appSettings
            appSettings.link(to: providerService)

            let jobsService = DefaultJobsManagerService(
                startServicesImmediately: appSettings.startServicesImmediately,
                allowExternalTraffic: appSettings.allowExternalTraffic
            )
            self.jobsService = jobsService

            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                // Terminate Jobs on exit
                jobsService.terminateAll()
            }
        }

        self.templates = Templates(modelData.mainContext)
    }

    func resetAllUserSettings() {
        DispatchQueue.main.async {
            UserDefaults.resetStandardUserDefaults()
            // This is needed for any HTTP 301's we left lying around during testing.
            URLCache.shared.removeAllCachedResponses()

            chatService.chatSequenceClientModels = []
            chatService.loadedChatSequences.removeAll()

            providerService.allModels = []
        }
    }

    var body: some Scene {
        WindowGroup(id: "8280", for: UUID.self) { _ in
            let blankViewModel = BlankSequenceViewModel(
                chatService: chatService,
                settings: CSCSettingsService.SettingsProxy(
                    defaults: chatSettingsService.defaults,
                    override: OverrideCSUISettings(),
                    inference: CSInferenceSettings()),
                chatSettingsService: chatSettingsService,
                appSettings: appSettings
            )

            AppWindowView(blankViewModel: blankViewModel)
                .environment(chatService)
                .environmentObject(jobsService)
                .environment(providerService)
                .environment(appSettings)
                .environment(chatSettingsService)
                .environment(templates)
                .modelContainer(modelData)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 1800)
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
                Button(action: {
                    windowState?.navigateToBlank()
                }, label: {
                    Text("New Chat")
                })
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(
                    windowState == nil
                )
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
                @Bindable var appSettings = appSettings
                @Bindable var chatSettingsService = chatSettingsService

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

                Toggle(isOn: $chatSettingsService.useSimplifiedOSV) {
                    Text("Use simplified chat interface")
                }

                Toggle(isOn: $chatSettingsService.useSimplifiedBlankOSV) {
                    Text("Use simplified chat interface when starting New Chats")
                }
            })
        }
    }
}
