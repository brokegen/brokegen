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
    @EnvironmentObject private var providerService: ProviderService
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var chatSettingsService: CSCSettingsService

    var settingsSection: some View {
        AppSidebarSection(isExpanded: appSettings.showDebugSidebarItems, label: {
            HStack {
                Image(systemName: "gear")
                    .padding(.trailing, 0)

                Text("Settings")
            }
        }) {
            NavigationLink(destination: ProvidersSidebar(providerService: providerService)) {
                ASRow("Providers", showChevron: true)
            }

            NavigationLink(destination: FoundationModelSettingsView(appSettings: appSettings)) {
                ASRow("Foundation Models", showChevron: true)
            }

            ASRow("Retrieval and Vector Stores", showChevron: true)
                .foregroundStyle(Color(.disabledControlTextColor))

            Divider()

            Toggle(isOn: $chatSettingsService.useSimplifiedOSV, label: {
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    MiniSequencePickerSidebar()

                    if appSettings.showDebugSidebarItems {
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
                        NavigationLink(destination: {
                            RefreshableModelPickerView()
                        }) {
                            ASRow("Foundation Models")
                        }

                        NavigationLink(destination: SequencePickerView(onlyUserPinned: false, showNewChatButton: false, showSequenceIds: true)) {
                            ASRow("ChatSequences", showChevron: true)
                        }

                        if appSettings.showDebugSidebarItems {
                            Divider()

                            ASRow("Chat Templates")
                                .foregroundStyle(Color(.disabledControlTextColor))

                            ASRow("Tokenization Check")
                                .foregroundStyle(Color(.disabledControlTextColor))

                            ASRow("Vector Stores")
                                .foregroundStyle(Color(.disabledControlTextColor))
                        }
                    }

                    MiniJobsSidebar()
                }
            }

            settingsSection
        }
        .listStyle(.sidebar)
        .toolbar(.hidden)
    }
}
