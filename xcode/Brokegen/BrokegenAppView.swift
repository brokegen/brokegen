import Combine
import SwiftUI

struct ASSStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label
                        .padding(4)
                        .font(.system(size: 24))
                        .foregroundStyle(Color(.controlTextColor))
                        .layoutPriority(0.5)

                    Spacer()

                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.left")
                        .contentTransition(.symbolEffect)
                        .padding()
                        .padding(.trailing, -12)
                }
                .padding(8)
            }

            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    configuration.content
                    // NB Animations don't work well within Lists.
                    // This only works for animating up
                        .transition(
                            .asymmetric(insertion: .push(from: .bottom),
                                        removal: .identity)
                        )
                        .padding([.top, .bottom], 12)
                }
                .font(.system(size: 18))
                .padding(12)
                .padding([.leading, .trailing], 24)
                .buttonStyle(.plain)
            }
        }
    }
}

struct AppSidebarSection<Label: View, Content: View>: View {
    @State var isExpanded: Bool = true
    let label: () -> Label
    let content: () -> Content

    init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content, label: label)
            .disclosureGroupStyle(ASSStyle())
    }
}

struct ASRow: View {
    let text: String
    let showChevron: Bool

    init(
        _ text: String,
        showChevron: Bool = false
    ) {
        self.showChevron = showChevron
        self.text = text
    }

    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1...2)
                .layoutPriority(0.5)
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .padding(.trailing, -12)
                    .font(.system(size: 10))
            }
        }
        .contentShape(Rectangle())
    }
}

struct AppSidebar: View {
    @Environment(InferenceModelSettings.self) private var inferenceModelSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    AppSidebarSection(label: {
                        HStack {
                            Image(systemName: "person.3")
                                .padding(.trailing, 0)
                            
                            Text("Agents")
                        }
                    }) {
                        ASRow("IRC revival")
                    }
                    .disabled(true)
                    .foregroundStyle(Color(.disabledControlTextColor))

                    MiniSequencePickerSidebar()

                    AppSidebarSection(label: {
                        Image(systemName: "sink")
                            .padding(.trailing, 0)
                        
                        Text("Experiments")
                    }) {
                        NavigationLink(destination: {
                            ModelPickerView()
                        }) {
                            ASRow("Model Inspector")
                        }
                        
                        ASRow("Non-chat completions")
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    MiniJobsSidebar()
                }
            }

            AppSidebarSection(label: {
                HStack {
                    Image(systemName: "gear")
                        .padding(.trailing, 0)
                    
                    Text("Settings")
                }
            }) {
                ASRow("Providers", showChevron: true)
                    .foregroundStyle(Color(.disabledControlTextColor))
                
                NavigationLink(value: inferenceModelSettings) {
                    ASRow("Defaults", showChevron: true)
                }
                
                NavigationLink(destination: SystemInfoView()) {
                    ASRow("System Info")
                }
                .padding(.bottom, 24)
            }
        }
        .listStyle(.sidebar)
        .toolbar(.hidden)
        .navigationDestination(for: InferenceModelSettings.self) { settings in
            InferenceModelSettingsView(settings)
        }
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
            .navigationDestination(for: ChatSequence.self) { sequence in
                NavigationSplitView(sidebar: { AppSidebar() }, detail: {
                    OneSequenceView(
                        chatService.clientModel(for: sequence, inferenceModelSettings: inferenceModelSettings)
                    )
                })
            }
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
