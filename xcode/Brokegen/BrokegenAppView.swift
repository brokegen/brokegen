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
    @Binding private var pathHost: PathHost
    @Environment(InferenceModelSettings.self) public var inferenceModelSettings

    init(pathHost: Binding<PathHost>) {
        _chatService = Environment(ChatSyncService.self)
        /// This Environment var has to be here and not the Scene, because we need to bind it directly to the NavigationStack it's for
        _pathHost = pathHost
    }

    var body: some View {
        NavigationStack(path: $pathHost.path) {
            NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                SequencePickerView()
                    .environmentObject(chatService)
            })
            .navigationDestination(for: ChatSequenceClientModel.self) { clientModel in
                NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                    OneSequenceView(clientModel)
                })
            }
        }
        .onAppear {
            // Do on-startup init, because otherwise we store no data and app is empty
            chatService.fetchPinnedSequences()
            providerService.fetchAvailableModels()
        }
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
    struct ViewHolder: View {
        @State private var pathHost = PathHost()

        var body: some View {
            BrokegenAppView(pathHost: $pathHost)
        }
    }

    return ViewHolder()
}
