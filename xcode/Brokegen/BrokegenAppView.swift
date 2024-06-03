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

struct AppSidebar: View {
    var body: some View {
        VStack {
            List {
                Section(header: HStack {
                    Image(systemName: "message")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(.leading, 4)
                        .padding(.trailing, -8)

                    Text("Chats")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(8)
                }) {
                    Divider()

                    NavigationLink(destination: MultiSequenceView()) {
                        HStack {
                            Text("Recent")
                                .font(.title2)
                                .padding(6)
                                .layoutPriority(0.5)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }

                    NavigationLink(destination: InferenceModelView()) {
                        HStack {
                            Text("Available Models")
                                .font(.title2)
                                .padding(6)
                                .layoutPriority(0.5)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                }

                Spacer()
                    .frame(maxHeight: 48)

                MiniJobsSidebar()
            }
            .layoutPriority(0.5)

            Spacer()
                .layoutPriority(0.2)

            List {
                Section(header: HStack {
                    Image(systemName: "gear")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(.leading, 4)
                        .padding(.trailing, -8)

                    Text("Settings")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(8)
                }) {
                    Divider()

                    HStack {
                        Text("Providers")
                            .font(.title2)
                            .padding(6)
                            .foregroundStyle(Color(.disabledControlTextColor))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    NavigationLink(destination: InferenceModelSettingsView()) {
                        Text("Defaults")
                            .font(.title2)
                            .padding(6)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }

                NavigationLink(destination: SystemInfoView()) {
                    Text("System Info")
                        .font(.title2)
                        .lineLimit(3)
                        .padding(6)
                }
            }
            .frame(height: 240)
            .scrollDisabled(true)
            .layoutPriority(1.0)
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
            .navigationDestination(for: ChatSequenceClientModel.self) { clientModel in
                NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                    OneSequenceView(clientModel)
                })
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

#Preview(traits: .fixedLayout(width: 1024, height: 1024)) {
    struct ViewHolder: View {
        @State private var pathHost = PathHost()

        var body: some View {
            BrokegenAppView(pathHost: $pathHost)
        }
    }

    return ViewHolder()
}
