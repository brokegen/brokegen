import SwiftUI

struct MiniSequencePickerSidebar: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @Environment(CSCSettingsService.self) public var chatSettingsService
    @Environment(AppSettings.self) public var appSettings
    let navLimit: Int

    @State private var timesRefreshClicked = 0

    init(navLimit: Int = maxSidebarItems) {
        self.navLimit = navLimit
    }

    func someSectionedSequences(limit: Int) -> [(String, [ChatSequence])] {
        let someSequences = Array(chatService.loadedChatSequences.values)
            .filter { $0.userPinned == true }
            .sorted()
            .prefix(limit)

        let sectionedSomeSequences = Dictionary(grouping: someSequences) {
            dateToSectionName($0.generatedAt)
        }

        return Array(sectionedSomeSequences)
            // Make sure the section names are sorted, because I guess they don't stay sorted
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
            NavigationLink(destination: {
                if chatSettingsService.useSimplifiedBlankOSV {
                    BlankSimpleOneSequenceView()
                }
                else {
                    BlankOneSequenceView()
                }
            }) {
                HStack {
                    Image(systemName: "plus")
                        .padding(.trailing, 0)
                        .layoutPriority(0.2)
                    Text("New Chat...")
                        .layoutPriority(0.5)
                    
                    Spacer()
                        .frame(minWidth: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(Color.accentColor)
            }
            .padding(.leading, -24)
            .padding(.trailing, -24)
            .frame(maxWidth: .infinity)
            
            if chatService.loadedChatSequences.isEmpty {
                if navLimit <= 0 {
                    NavigationLink(destination: SequencePickerView(onlyUserPinned: true)) {
                        ASRow("Browse Pinned", showChevron: true)
                    }
                }
                else {
                    if timesRefreshClicked > 0 {
                        // TODO: This always shows for a bit while ChatSyncService is updating,
                        // do something with ProgressView and timeouts.
                        Button("Refresh Chats List", systemImage: "arrow.clockwise") {
                            timesRefreshClicked += 1
                            Task { try? await chatService.fetchRecents(limit: navLimit, onlyUserPinned: true) }
                        }
                        .padding(.leading, -24)
                        .padding(.trailing, -24)
                    }
                    else {
                        Button("Load Chats", systemImage: "arrow.clockwise") {
                            timesRefreshClicked += 1
                            Task {
                                try? await chatService.fetchRecents(limit: navLimit, onlyUserPinned: true)
                                try? await chatService.fetchRecents(limit: navLimit, onlyUserPinned: false)
                            }
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, -24)
                        .padding(.trailing, -24)
                    }
                }
            }
            else {
                NavigationLink(destination: SequencePickerView(onlyUserPinned: true)) {
                    ASRow("Pinned Chats", showChevron: true)
                }
                NavigationLink(destination: SequencePickerView(onlyUserPinned: false)) {
                    ASRow("Pinned + Recent", showChevron: true)
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
                            .monospaced()
                    })
                }
                .padding(.leading, -24)
                .padding(.trailing, -24)
            }
        }
        .onAppear {
            Task {
                try? await chatService.fetchRecents(limit: navLimit, onlyUserPinned: true)
                try? await chatService.fetchRecents(limit: navLimit, onlyUserPinned: false)
            }
        }
    }

    func sidebarRow(_ sequence: ChatSequence) -> some View {
        HStack(alignment: .top, spacing: 0) {
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
                    Text(sequence.displayHumanDesc())
                        .lineLimit(1...2)
                        .layoutPriority(0.5)
                        .padding(.trailing, -12)
                        .id("\(sequence.id) text")

                    if sequence.messages.count > 4 {
                        HStack(spacing: 0) {
                            Spacer()
                                .frame(minWidth: 0)

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
        .contextMenu {
            Text(sequence.displayRecognizableDesc())

            Divider()
            
            Section(header: Text("Chat Data")) {
                Button {
                    chatService.pin(sequenceId: sequence.serverId, pinned: !sequence.userPinned)
                } label: {
                    Toggle(isOn: .constant(sequence.userPinned)) {
                        Text("Pin ChatSequence in sidebar")
                    }
                }

                Button {
                    Task { @MainActor in
                        _ = try? await chatService.autonameBlocking(sequenceId: sequence.serverId, preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId)
                    }
                } label: {
                    Text(appSettings.stillPopulating
                         ? "Autoname disabled (still loading)"
                         : (appSettings.preferredAutonamingModel == nil
                            ? "Autoname disabled (set a model in settings)"
                            : "Autoname with: \(appSettings.preferredAutonamingModel!)")
                    )
                }
                .disabled(appSettings.preferredAutonamingModel == nil)

                Button {
                    Task {
                        if let refreshedSequence = try? await chatService.fetchChatSequenceDetails(sequence.serverId) {
                            DispatchQueue.main.async {
                                self.chatService.updateSequence(withSameId: refreshedSequence)
                            }
                        }
                    }
                } label: {
                    Text("Force ChatSequence data refresh...")
                }
            }
        }
    }
}
