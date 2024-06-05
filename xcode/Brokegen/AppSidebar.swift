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
    @Environment(ProviderService.self) private var providerService
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
            InferenceModelSettingsView()
                .environmentObject(settings.inflateModels(providerService))
        }
    }
}
