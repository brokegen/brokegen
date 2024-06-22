import SwiftUI

struct MiniSequencePickerSidebar: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @EnvironmentObject public var chatSettingsService: CSCSettingsService
    @EnvironmentObject public var appSettings: AppSettings
    let navLimit: Int

    @State private var timesRefreshClicked = 0

    init(navLimit: Int = maxSidebarItems) {
        self.navLimit = navLimit
    }

    func someSectionedSequences(limit: Int) -> [(String, [ChatSequence])] {
        let someSequences = chatService.loadedChatSequences
            .sorted()
            .prefix(limit)

        let sectionedSomeSequences = Dictionary(grouping: someSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSomeSequences)
            // Make sure the section names are sorted, because I guess they don't stay sorted
            .sorted { $0.0 > $1.0 }
    }

    func sectionedSequences() -> [(String, [ChatSequence])] {
        let sectionedSequences = Dictionary(grouping: chatService.loadedChatSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSequences)
            .map {
                // Sort the individual ChatSequences within a section
                ($0.0, $0.1.sorted())
            }
            .sorted { $0.0 > $1.0 }
    }

    var body: some View {
        AppSidebarSection(label: {
            HStack {
                Image(systemName: "message")
                    .padding(.trailing, 4)

                Text("Chats")
            }
        }) {
            if chatSettingsService.useSimplifiedSequenceViews {
                NavigationLink(destination: {
                    BlankOneSequenceView()
                }) {
                    HStack {
                        Image(systemName: "plus")
                            .padding(.trailing, 0)
                            .layoutPriority(0.2)
                        Text("New Chat...")
                            .layoutPriority(0.5)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.leading, -24)
                .padding(.trailing, -24)
                .frame(maxWidth: .infinity)
            }
            else {
                NavigationLink(destination: {
                    ProSequenceView(
                        OneSequenceViewModel.createBlank(chatService: chatService, appSettings: appSettings, chatSettingsService: chatSettingsService)
                    )
                }) {
                    Image(systemName: "plus")
                        .padding(.trailing, 0)
                        .layoutPriority(0.2)
                    Text("New Chat (experimental)")
                        .layoutPriority(0.5)

                    Spacer()
                }
                .padding(.leading, -24)
                .padding(.trailing, -24)
                .frame(maxWidth: .infinity)
            }

            if chatService.loadedChatSequences.isEmpty {
                if navLimit <= 0 {
                    NavigationLink(destination: SequencePickerView()) {
                        ASRow("Browse Recent", showChevron: true)
                    }
                }
                else {
                    if timesRefreshClicked > 0 {
                        // TODO: This always shows for a bit while ChatSyncService is updating,
                        // do something with ProgressView and timeouts.
                        Button("Refresh Chats List", systemImage: "arrow.clockwise") {
                            timesRefreshClicked += 1
                            Task { try? await chatService.refreshPinnedChatSequences(limit: navLimit) }
                        }
                        .padding(.leading, -24)
                        .padding(.trailing, -24)
                    }
                    else {
                        Button("Load Chats", systemImage: "arrow.clockwise") {
                            timesRefreshClicked += 1
                            Task { try? await chatService.refreshPinnedChatSequences(limit: navLimit) }
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, -24)
                        .padding(.trailing, -24)
                    }
                }
            }
            else {
                NavigationLink(destination: SequencePickerView()) {
                    ASRow("Browse Recent", showChevron: true)
                }

                Divider()

                ForEach(someSectionedSequences(limit: navLimit), id: \.0) { pair in
                    let (sectionName, sectionSequences) = pair

                    Section(content: {
                        ForEach(sectionSequences, id: \.serverId) { sequence in
                            Button(action: {
                                pathHost.push(
                                    chatService.clientModel(for: sequence, appSettings: appSettings, chatSettingsService: chatSettingsService)
                                )
                            }, label: {
                                sidebarRow(sequence)
                            })
                        }
                    }, header: {
                        Text(sectionName)
                            .padding(-6)
                            .padding(.top, 12)
                            .foregroundStyle(Color(.disabledControlTextColor))
                            .font(.system(size: 16))
                    })
                }
                .padding(.leading, -24)
                .padding(.trailing, -24)
            }
        }
    }

    func sidebarRow(_ sequence: ChatSequence) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: "bubble")
                .padding(.leading, -4)
                .padding(.top, 2)
                .padding(.trailing, 8)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    Text(sequence.displayHumanDesc())
                        .lineLimit(1...2)
                        .layoutPriority(0.5)
                        .padding(.trailing, -12)
                        .id("\(sequence.id) text")

                    Spacer()

                    if sequence.messages.count > 4 {
                        Text("\(sequence.messages.count) messages")
                            .lineLimit(1)
                            .font(.system(size: 16))
                            .foregroundStyle(Color(.disabledControlTextColor))
                            .layoutPriority(0.2)
                            .padding(.leading, 12)
                            .id("\(sequence.id) count")
                    }
                } // first ViewThatFits option: HStack

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text(sequence.displayHumanDesc())
                            .lineLimit(1...2)
                            .layoutPriority(0.5)
                            .padding(.trailing, -12)
                            .id("\(sequence.id) text")

                        Spacer()
                    }

                    if sequence.messages.count > 4 {
                        HStack(spacing: 0) {
                            Spacer()

                            Text("\(sequence.messages.count) messages")
                                .lineLimit(1)
                                .font(.system(size: 16))
                                .foregroundStyle(Color(.disabledControlTextColor))
                                .layoutPriority(0.2)
                                .padding(.top, 4)
                                .id("\(sequence.id) count")
                        }
                    }
                } // second ViewThatFits option: overflow VStack
            }
        }
    }
}
