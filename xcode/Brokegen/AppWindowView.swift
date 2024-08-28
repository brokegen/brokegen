import SwiftUI

extension OneSequenceViewModel: CustomStringConvertible {
    var description: String {
        return "OneSequenceViewModel: \(self.sequence.displayRecognizableDesc())"
    }
}

@Observable
class PathHost {
    var path: NavigationPath = NavigationPath()
    var inspectablePathItems: [any Hashable] = []

    public func printIt(_ prefix: String = "") {
        print(prefix)
        for item in inspectablePathItems {
            print("- \(String(describing: item))")
        }
    }

    public func push<V>(_ pather: V) -> Void where V:Hashable {
        path.append(pather)
        inspectablePathItems.append(pather)
        printIt("[DEBUG] PathHost.push(), \(path.count) items total")
    }

    public func pop(_ k: Int = 1) {
        printIt("[DEBUG] About to PathHost.pop(), currently \(path.count) items")
        inspectablePathItems.removeLast(k)
        path.removeLast(k)
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

struct AppWindowView: View {
    @Environment(CSCSettingsService.self) private var chatSettingsService
    @StateObject private var windowState: WindowViewModel

    init(blankViewModel: BlankSequenceViewModel) {
        self._windowState = StateObject(wrappedValue: WindowViewModel(blankViewModel: blankViewModel))
    }

    var body: some View {
        let sharedSidebar = AppSidebar()
            .navigationSplitViewColumnWidth(ideal: 360)

        NavigationStack(path: $windowState.pathHost.path) {
            NavigationSplitView(sidebar: {
                sharedSidebar
            }, detail: {
                SequencePickerView()
            })
            .navigationDestination(for: OneSequenceViewModel.self) { clientModel in
                NavigationSplitView(sidebar: {
                    sharedSidebar
                }, detail: {
                    if chatSettingsService.useSimplifiedOSV {
                        SimpleOneSequenceView(clientModel)
                    }
                    else {
                        OneSequenceView(clientModel)
                    }
                })
            }
            .navigationDestination(for: WindowViewModel.BLANK_CHAT.self) { _ in
                NavigationSplitView(sidebar: {
                    sharedSidebar
                }, detail: {
                    if chatSettingsService.useSimplifiedBlankOSV {
                        BlankSimpleOneSequenceView()
                    }
                    else {
                        BlankOneSequenceView()
                    }
                })
            }
        }
        .frame(idealWidth: 960)
        // Without this, shrinking the window shows a weird grey blank area on the left
        .frame(minWidth: 640)
        .environment(windowState.pathHost)
        .environment(windowState.blankViewModel)
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

    return AppSidebar()
        .environmentObject(jobs)
}
