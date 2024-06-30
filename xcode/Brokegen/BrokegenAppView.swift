import SwiftUI

@Observable
class PathHost: ObservableObject {
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

class WindowViewModel: ObservableObject {
    struct BLANK_CHAT: Hashable {
        public func hash(into hasher: inout Hasher) {
            hasher.combine(7)
        }
    }

    var pathHost: PathHost = PathHost()
    var blankViewModel: BlankSequenceViewModel

    init(blankViewModel: BlankSequenceViewModel) {
        self.blankViewModel = blankViewModel
    }

    func navigateToBlank() {
        self.pathHost.push(BLANK_CHAT())
    }
}

struct BrokegenAppView: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @EnvironmentObject private var providerService: ProviderService
    @EnvironmentObject public var chatSettingsService: CSCSettingsService
    @EnvironmentObject public var appSettings: AppSettings

    @StateObject private var windowState: WindowViewModel

    init(blankViewModel: BlankSequenceViewModel) {
        self._windowState = StateObject(wrappedValue: WindowViewModel(blankViewModel: blankViewModel))
    }

    var body: some View {
        let sharedSidebar = AppSidebar(
            useSimplifiedSequenceViews: $chatSettingsService.useSimplifiedSequenceViews,
            showDebugSidebarItems: $appSettings.showDebugSidebarItems
        )
            .navigationSplitViewColumnWidth(ideal: 360)

        NavigationStack(path: $windowState.pathHost.path) {
            NavigationSplitView(sidebar: {
                sharedSidebar
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
            .navigationDestination(for: WindowViewModel.BLANK_CHAT.self) { _ in
                NavigationSplitView(sidebar: {
                    sharedSidebar
                }, detail: {
                    if chatSettingsService.useSimplifiedBlankOSV {
                        BlankOneSequenceView()
                    }
                    else {
                        BlankProSequenceView()
                    }
                })
            }
        }
        .environmentObject(windowState.pathHost)
        .environmentObject(windowState.blankViewModel)
        .focusedSceneObject(windowState)
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
        .environmentObject(jobs)
}
