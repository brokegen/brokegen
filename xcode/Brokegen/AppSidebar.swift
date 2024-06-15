import SwiftUI

struct ASSStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    configuration.label
                        .padding(4)
                        .font(.system(size: 24))
                        .foregroundStyle(Color(.controlTextColor))
                        .layoutPriority(0.5)

                    Spacer()

                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.left")
                        .contentTransition(.symbolEffect)
                        .padding()
                        .padding(.trailing, -6)
                        .layoutPriority(0.2)
                }
                .frame(height: 60)
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
    @State var isExpanded: Bool
    let label: () -> Label
    let content: () -> Content

    init(
        isExpanded: Bool = true,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
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
        HStack(alignment: .top, spacing: 0) {
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
    @Environment(ProviderService.self) private var providerService
    @Environment(InferenceModelSettings.self) private var inferenceModelSettings

    @AppStorage("showDebugSidebarItems")
    private var showDebugSidebarItems: Bool = true
    @AppStorage("allowExternalTraffic")
    private var allowExternalTraffic: Bool = false
    @Binding private var useSimplifiedSequenceViews: Bool
    private var bigReset: (() -> Void)

    init(
        useSimplifiedSequenceViews: Binding<Bool>,
        bigReset: (@escaping () -> Void)
    ) {
        self._useSimplifiedSequenceViews = useSimplifiedSequenceViews
        self.bigReset = bigReset
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    MiniSequencePickerSidebar()

                    if showDebugSidebarItems {
                        AppSidebarSection(isExpanded: false, label: {
                            HStack {
                                Image(systemName: "person.3")
                                    .padding(.trailing, 0)

                                Text("Agents")
                            }
                        }) {
                            ASRow("IRC Simulator")
                                .disabled(true)
                                .foregroundStyle(Color(.disabledControlTextColor))
                        }
                    }

                    AppSidebarSection(label: {
                        Image(systemName: "sink")
                            .padding(.trailing, 0)

                        Text("Inspectors")
                    }) {
                        if showDebugSidebarItems {
                            NavigationLink(destination: SystemInfoView()) {
                                ASRow("System Info")
                            }
                        }

                        NavigationLink(destination: ProviderPickerView(providerService: providerService)) {
                            ASRow("Providers")
                        }

                        NavigationLink(destination: {
                            ModelPickerView()
                        }) {
                            ASRow("Inference Models")
                        }

                        Divider()

                        ASRow("Chat Templates")
                            .foregroundStyle(Color(.disabledControlTextColor))

                        ASRow("Tokenization Check")
                            .foregroundStyle(Color(.disabledControlTextColor))

                        ASRow("Vector Stores")
                            .foregroundStyle(Color(.disabledControlTextColor))

                        if showDebugSidebarItems {
                            Divider()

                            ASRow("InferenceJobs")
                                .foregroundStyle(Color(.disabledControlTextColor))

                            ASRow("ChatSequences")
                                .foregroundStyle(Color(.disabledControlTextColor))

                            ASRow("ChatMessages")
                                .foregroundStyle(Color(.disabledControlTextColor))
                        }
                    }

                    MiniJobsSidebar()
                }
            }

            AppSidebarSection(isExpanded: showDebugSidebarItems, label: {
                HStack {
                    Image(systemName: "gear")
                        .padding(.trailing, 0)

                    Text("Settings")
                }
            }) {
                ASRow("Providers", showChevron: true)
                    .foregroundStyle(Color(.disabledControlTextColor))

                NavigationLink(value: inferenceModelSettings) {
                    ASRow("Inference Models", showChevron: true)
                }

                ASRow("Retrieval and Vector Stores", showChevron: true)
                    .foregroundStyle(Color(.disabledControlTextColor))

                Divider()

                if showDebugSidebarItems {
                    HStack(spacing: 0) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.yellow)
                            .padding(.trailing, 8)

                        Text("Reset all client state (long press)")
                    }
                    .onLongPressGesture {
                        bigReset()
                    }
                    .padding(.leading, -24)
                }

                Toggle(isOn: $showDebugSidebarItems, label: {
                    HStack(spacing: 0) {
                        // TODO: We really shouldn't need to restart the app. Probably something to do with explicit View id's
                        Text("Show debug sidebar items (restart app to propagate changes)")
                            .layoutPriority(0.2)

                        Spacer()
                    }
                })
                .toggleStyle(.switch)
                .padding(.trailing, -12)

                Toggle(isOn: $allowExternalTraffic, label: {
                    HStack(spacing: 0) {
                        Text("Allow non-localhost traffic")
                            .layoutPriority(0.2)

                        Spacer()
                    }
                })
                .toggleStyle(.switch)
                .padding(.trailing, -12)

                Toggle(isOn: $useSimplifiedSequenceViews, label: {
                    HStack(spacing: 0) {
                        Text("Use simplified chat interface")
                            .layoutPriority(0.2)
                        
                        Spacer()
                    }
                })
                .toggleStyle(.switch)
                .padding(.trailing, -12)
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

struct AppMenus: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            NavigationLink(destination: EmptyView(), label: {
                Text("New Chat")
            })
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(action: {
            }, label: {
                Text("Toggle Sidebar")
            })
        }
    }
}
