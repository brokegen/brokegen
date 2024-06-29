import SwiftUI

@Observable
class PathHost {
    var path: NavigationPath = NavigationPath()

    public func printIt(_ prefix: String = "") {
        print(prefix + String(describing: path))
    }

    public func push<V>(_ pather: V) -> Void where V:Hashable {
        path.append(pather)
        printIt("[DEBUG] PathHost.push ")
    }

    public func pop(_ k: Int = 1) {
        printIt("[DEBUG] PathHost.pop ")
        return path.removeLast(k)
    }
}

struct BrokegenAppView: View {
    @Environment(ChatSyncService.self) private var chatService
    @Environment(ProviderService.self) private var providerService
    // This is the only one that really belongs here, because multiple windows
    @State private var pathHost: PathHost = PathHost()
    @EnvironmentObject public var chatSettingsService: CSCSettingsService
    @EnvironmentObject public var appSettings: AppSettings

    var body: some View {
        // TODO: Should this be done a different way, somehow?
        // How do I get these to share state and not "jump" during navigation?
        let sharedSidebar = AppSidebar(
            useSimplifiedSequenceViews: $chatSettingsService.useSimplifiedSequenceViews,
            showDebugSidebarItems: $appSettings.showDebugSidebarItems
        )

        NavigationStack(path: $pathHost.path) {
            NavigationSplitView(sidebar: {
                sharedSidebar
                    .navigationSplitViewColumnWidth(ideal: 360)
            }, detail: {
                SequencePickerView(onlyUserPinned: true)
            })
            .navigationDestination(for: OneSequenceViewModel.self) { clientModel in
                NavigationSplitView(sidebar: {
                    sharedSidebar
                }, detail: {
                    if chatSettingsService.useSimplifiedSequenceViews {
                        OneSequenceView(clientModel)
                    }
                    else {
                        ProSequenceView(clientModel)
                    }
                })
            }
        }
        .environment(pathHost)
        .environmentObject(BlankSequenceViewModel(
            chatService: chatService,
            settings: CSCSettingsService.SettingsProxy(
                defaults: chatSettingsService.defaults,
                override: OverrideCSUISettings(),
                inference: CSInferenceSettings()),
            chatSettingsService: chatSettingsService,
            appSettings: appSettings
        ))
    }
}

#Preview(traits: .fixedLayout(width: 400, height: 800)) {
    let jobs = JobsManagerService()
    for index in 1...20 {
        let job = TimeJob("Job \(index)")
        if index < 4 {
            jobs.sidebarRenderableJobs.append(job)
        }

        jobs.storedJobs.append(job)
    }

    return AppSidebar(useSimplifiedSequenceViews: Binding.constant(true), showDebugSidebarItems: .constant(true))
        .environment(jobs)
}

#Preview(traits: .fixedLayout(width: 1024, height: 1024)) {
    BrokegenAppView()
}
