import Combine
import SwiftUI

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

                    NavigationLink(destination: SequencePickerView()) {
                        HStack {
                            Text("Recent")
                                .font(.title2)
                                .padding(6)
                                .layoutPriority(0.5)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }

                    NavigationLink(destination: ModelPickerView()) {
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

                // TODO: ViewThatFits
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
                            .layoutPriority(0.5)
                            .foregroundStyle(Color(.disabledControlTextColor))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    NavigationLink(destination: InferenceModelSettingsView()) {
                        HStack {
                            Text("Defaults")
                                .font(.title2)
                                .padding(6)
                                .layoutPriority(0.5)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
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
        .frame(maxHeight: .infinity)
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
    @Environment(JobsManagerService.self) private var jobsService
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
                JobPickerView(jobsService.storedJobs)
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
