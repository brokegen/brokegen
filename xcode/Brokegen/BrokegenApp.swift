import Combine
import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    @State private var chatService: ChatSyncService = ChatSyncService()
    @State private var jobsService: JobsManagerService = DefaultJobsManagerService()
    @State private var providerService: ProviderService = ProviderService()

    private var inferenceSettings = InferenceSettingsService()
    @State private var inferenceSettingsUpdater: AnyCancellable? = nil
    @StateObject private var chatSettingsService = CSCSettingsService()

    init() {
        // Do on-startup init, because otherwise we store no data and app is empty
        callInitializers()
    }

    func callInitializers() {
        inferenceSettingsUpdater = providerService.$allModels.sink { _ in
            inferenceSettings.inflateModels(providerService)
        }

        Task {
            _ = try? await providerService.fetchAllProviders()
            await providerService.fetchAvailableModels()
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
                .environment(chatSettingsService.sequenceSettings)
                .environmentObject(chatSettingsService)
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
