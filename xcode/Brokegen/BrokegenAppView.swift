import Combine
import SwiftUI

struct RadialLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // accept the full proposed space, replacing any nil values with a sensible default
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // calculate the radius of our bounds
        let radius = min(bounds.size.width, bounds.size.height) / 2

        // figure out the angle between each subview on our circle
        let angle = Angle.degrees(360 / Double(subviews.count)).radians

        for (index, subview) in subviews.enumerated() {
            // ask this view for its ideal size
            let viewSize = subview.sizeThatFits(.unspecified)

            // calculate the X and Y position so this view lies inside our circle's edge
            let xPos = cos(angle * Double(index) - .pi / 2) * (radius - viewSize.width / 2)
            let yPos = sin(angle * Double(index) - .pi / 2) * (radius - viewSize.height / 2)

            // position this view relative to our centre, using its natural size ("unspecified")
            let point = CGPoint(x: bounds.midX + xPos, y: bounds.midY + yPos)
            subview.place(at: point, anchor: .center, proposal: .unspecified)
        }
    }
}

struct SettingsBlob: View {
    var body: some View {
        RadialLayout {
            NavigationLink(destination: SystemInfoView()) {
                Text("System Info")
                    .font(.title2)
            }
            .padding(6)

            Text("Settings")
                .font(.title2)
                .foregroundStyle(.secondary)

            NavigationLink(destination: PlaceholderContentView("INFERENCE")) {
                Label("Inference", systemImage: "slider.horizontal.3")
                    .font(.title3)
                    .padding(24)
            }
            NavigationLink(destination: PlaceholderContentView("RETRIEVAL")) {
                Label("Retrieval", systemImage: "slider.horizontal.3")
                    .font(.title3)
            }
            NavigationLink(destination: PlaceholderContentView("AGENCE")) {
                Label("A gents", systemImage: "slider.horizontal.3")
                    .font(.title3)
            }

            Text("Agents")
            .padding(12)
        }
        .frame(width: 380)
    }

    var bodyDisabled: some View {
        VStack(alignment: .trailing) {
            Divider()

            NavigationLink(destination: SystemInfoView()) {
                Text("System Info")
                    .font(.title2)
            }
            .padding(6)

            Group {
                Text("Settings")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                NavigationLink(destination: PlaceholderContentView("INFERENCE")) {
                    Label("Inference", systemImage: "slider.horizontal.3")
                        .font(.title3)
                }
                NavigationLink(destination: PlaceholderContentView("RETRIEVAL")) {
                    Label("Retrieval", systemImage: "slider.horizontal.3")
                        .font(.title3)
                }
                NavigationLink(destination: PlaceholderContentView("AGENCE")) {
                    Label("A gents", systemImage: "slider.horizontal.3")
                        .font(.title3)
                }

                Text("Agents")
                .padding(12)
            }
            .padding(6)
        }
    }
}

struct AppSidebar: View {
    var body: some View {
        List {
            NavigationLink(destination: SystemInfoView()) {
                Text("System Info")
                    .font(.title2)
                    .lineLimit(3)
                    .padding(6)
            }

            Section(header: Text("Chats")
                .font(.largeTitle)
                .padding(6)
            ) {
                NavigationLink(destination: MultiSequenceView()) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Recent")
                        .font(.title2)
                        .padding(6)
                    Spacer()
                    Image(systemName: "chevron.right")
                }

                NavigationLink(destination: InferenceModelView()) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Available Models")
                        .font(.title2)
                        .padding(6)
                    Spacer()
                    Image(systemName: "plus.message")
                }
            }

            Divider()

            MiniJobsSidebar()

            Divider()

            Section(header: Label("Settings", systemImage: "gear")
                .font(.largeTitle)
                .padding(6)
            ) {
                HStack {
                    Text("Providers")
                        .font(.title2)
                        .padding(6)
                }

                NavigationLink(destination: InferenceModelSettingsView()) {
                    Text("Defaults")
                        .font(.title2)
                        .padding(6)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 400, maxHeight: .infinity)
        .toolbar(.hidden)
    }
}

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

    init(pathHost: Binding<PathHost>) {
        _chatService = Environment(ChatSyncService.self)
        /// This Environment var has to be here and not the Scene, because we need to bind it directly to the NavigationStack it's for
        _pathHost = pathHost
    }

    var body: some View {
        NavigationStack(path: $pathHost.path) {
            NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                MultiSequenceView()
            })
            .navigationDestination(for: ChatSequence.self) { sequence in
                NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                    OneSequenceView(
                        chatService.clientModel(for: sequence)
                    )
                })
                .environment(chatService)
                .environment(pathHost)
            }
            .navigationDestination(for: ChatSequenceParameters.self) { params in
                NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                    OneSequenceView(
                        chatService.clientModel(for: params.sequence!)
                            .requestContinue(model: params.continuationModelId)
                    )
                })
                .environment(chatService)
                .environment(pathHost)
            }
        }
        .environment(chatService)
        .environment(pathHost)
        .onAppear {
            // Do on-startup init, because otherwise we store no data and app is empty
            chatService.fetchPinnedSequences()
            providerService.fetchAvailableModels()
        }
    }
}

#Preview(traits: .fixedLayout(width: 1024, height: 400)) {
    SettingsBlob()
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
