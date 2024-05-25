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

struct AppView: View {
    @Environment(ChatSyncService.self) private var chatService

    var body: some View {
        NavigationSplitView(sidebar: {
            List {
                Section(header: Text("Chats")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .padding(6)
                ) {
                    NavigationLink(destination: SequencesView()) {
                        Spacer()
                        Label("[All Chats]", systemImage: "slider.horizontal.3")
                    }
                    .frame(maxWidth: .infinity)

                    NavigationLink(destination: SequencesView()) {
                        Spacer()
                        Label("Import", systemImage: "paperplane")
                            .onAppear {
                                chatService.fetchPinnedSequences()
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(12)

                Divider()
                MiniJobsSidebar()

                NavigationLink(destination: SystemInfoView()) {
                    Text("System Info")
                        .font(.title2)
                        .lineLimit(3)
                }
                .padding(32)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 400, maxHeight: .infinity)
            .toolbar(.hidden)
        }, detail: {
            SequencesView()
        })
        .navigationTitle("")
    }
}

#Preview(traits: .fixedLayout(width: 1024, height: 400)) {
    SettingsBlob()
}

#Preview(traits: .fixedLayout(width: 1024, height: 1024)) {
    AppView()
}
