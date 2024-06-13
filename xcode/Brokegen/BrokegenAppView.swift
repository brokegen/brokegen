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
    @Environment(InferenceModelSettings.self) public var inferenceModelSettings

    @State private var sidebarVisibility = NavigationSplitViewVisibility.automatic
    @State private var sidebarVisibilityTimesChanged: Int = 0

    var body: some View {
        NavigationStack(path: $pathHost.path) {
            NavigationSplitView(columnVisibility: $sidebarVisibility, sidebar: { AppSidebar() }, detail: {
                SequencePickerView()
                    .environmentObject(chatService)
            })
            .navigationDestination(for: ChatSequenceClientModel.self) { clientModel in
                NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                    ProSequenceView(clientModel)
                })
            }
            // Show the sidebar on initial re-load
            // TODO: Once we have keyboard shortcuts or context menus, use those to re-show the sidebar.
            .onChange(of: sidebarVisibility, initial: true) { oldValue, newValue in
                if sidebarVisibilityTimesChanged < 1 {
                    if newValue == .detailOnly {
                        sidebarVisibilityTimesChanged += 1
                        DispatchQueue.main.async {
                            sidebarVisibility = .all
                        }
                    }
                }
            }
        }
        .environment(pathHost)
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

    return AppSidebar()
        .environment(jobs)
}

#Preview(traits: .fixedLayout(width: 1024, height: 1024)) {
    BrokegenAppView()
}
