import SwiftUI

let maxSidebarItems = 8

fileprivate func dateToString(_ date: Date) -> String {
    let calendar = Calendar(identifier: .iso8601)
    let chatDate = calendar.startOfDay(for: date)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    return dateFormatter.string(from: chatDate)
}

fileprivate func dateToISOWeek(_ date: Date) -> String {
    let formatter = DateFormatter()
    // en_US_POSIX is specifically designed to return fixed format, English dates
    // https://developer.apple.com/library/archive/qa/qa1480/_index.html
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(abbreviation: "UTC")
    formatter.dateFormat = "YYYY-'ww'ww.e-LLL-dd"

    return formatter.string(from: date)
}

func dateToISOWeekStartingMonday(_ date: Date) -> String {
    // Manually fetch the day-of-week, because dateFormat 'e' counts days from Sunday.
    let calendar = Calendar(identifier: .iso8601)
    let components = calendar.dateComponents(
        [.yearForWeekOfYear, .weekOfYear, .weekday, .month, .day], from: date)

    var paddedYear = String(format: "%04d", components.yearForWeekOfYear!)
    var paddedWeek = String(format: "%02d", components.weekOfYear!)
    var weekday = components.weekday! - 1

    // For Sundays, we need to bump everything back by one.
    if weekday == 0 {
        let yesterdayComponents = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: calendar.date(byAdding: .day, value: -1, to: date)!)
        paddedYear = String(format: "%04d", yesterdayComponents.yearForWeekOfYear!)
        paddedWeek = String(format: "%02d", yesterdayComponents.weekOfYear!)
        weekday = 7
    }

    // We need a DateFormatter to get month name(s).
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(abbreviation: "UTC")

    formatter.dateFormat = "'-'LLL'-'dd"
    return "\(paddedYear)-ww\(paddedWeek).\(weekday)" + formatter.string(from: date)
}

fileprivate func nocacheDateToSectionName(_ date: Date) -> String {
    let sectionName = dateToISOWeekStartingMonday(date)

    // If the date was more than a week ago, just return the week-name
    if date.timeIntervalSinceNow < -168 * 24 * 3600 {
        return String(sectionName.prefix(9))
    }

    // If it's in the previous week, truncate so it's just the week-name
    let todaySection = dateToISOWeekStartingMonday(Date.now)
    if sectionName.prefix(9) != todaySection.prefix(9) {
        return String(sectionName.prefix(9))
    }

    return sectionName
}

fileprivate var cachedSectionNames: [Date : String] = [:]

func dateToSectionName(_ date: Date?) -> String {
    // NB This "default" name should sort later than the ones starting 2024-wwXX
    guard date != nil else { return "0000 no date" }

    if let foundName = cachedSectionNames[date!] {
        return foundName
    }
    else {
        let madeName = nocacheDateToSectionName(date!)
        cachedSectionNames[date!] = madeName
        return madeName
    }
}

extension ChatSequence: Comparable {
    static func < (lhs: ChatSequence, rhs: ChatSequence) -> Bool {
        if lhs.lastMessageDate == nil {
            return false
        }
        if rhs.lastMessageDate == nil {
            return true
        }

        if lhs.lastMessageDate == rhs.lastMessageDate {
            return lhs.parentSequences?.count ?? -1 > rhs.parentSequences?.count ?? -1
        }

        return lhs.lastMessageDate! > rhs.lastMessageDate!
    }
}

func sectionedSequences(
    _ loadedChatSequences: [ChatSequenceServerID : ChatSequence],
    onlyUserPinned: Bool
) -> [(String, [ChatSequence])] {
    let startTime = Date.now

    var sortedSequences = Array(loadedChatSequences.values)
    if onlyUserPinned {
        sortedSequences = sortedSequences.filter {
            $0.userPinned == true || $0.isLeafSequence == true
        }
    }
    sortedSequences = sortedSequences.sorted()

    let sectionedSequences = Dictionary(grouping: sortedSequences) {
        dateToSectionName($0.lastMessageDate)
    }

    let result = Array(sectionedSequences)
        .sorted { $0.0 > $1.0 }

    let elapsedMsec = Date.now.timeIntervalSince(startTime) * 1000
    if elapsedMsec > 8.333 {
        let args: String = onlyUserPinned ? "onlyUserPinned: true" : ""
        print("[TRACE] ChatSyncService.sectionedSequences(\(args)) generation time: \(String(format: "%.3f", elapsedMsec)) msec for \(loadedChatSequences.count) rows")
    }

    return result
}

// MARK: - actual SequencePicker
struct SequencePickerView: View {
    @Environment(ChatSyncService.self) private var chatService
    @Environment(PathHost.self) private var pathHost
    @Environment(AppSettings.self) public var appSettings
    @Environment(CSCSettingsService.self) public var chatSettingsService

    let onlyUserPinned: Bool
    let showNewChatButton: Bool
    let showSequenceIds: Bool

    @State private var isRenaming: [ChatSequence] = []

    init(onlyUserPinned: Bool = true, showNewChatButton: Bool = true, showSequenceIds: Bool = false) {
        self.onlyUserPinned = onlyUserPinned
        self.showNewChatButton = showNewChatButton
        self.showSequenceIds = showSequenceIds
    }

    @ViewBuilder
    func sectionContextMenu(for sectionName: String, sequences: [ChatSequence]) -> some View {
        Button {
            for sequence in sequences {
                _ = chatService.autonameChatSequence(sequence, preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId)
            }
        } label: {
            Text(appSettings.preferredAutonamingModel == nil
                 ? "Autoname \(sequences.count) sequences (disabled, select a preferred model first)"
                 : "Autoname \(sequences.count) sequences")
                .font(.system(size: 18))
        }
        .disabled(appSettings.preferredAutonamingModel == nil)
    }

    @ViewBuilder
    func sequenceContextMenu(for sequence: ChatSequence) -> some View {
        Text(sequence.displayRecognizableDesc())

        Divider()

        Section(header: Text("Chat Data")) {
            Button {
                chatService.pinChatSequence(sequence, pinned: !sequence.userPinned)
            } label: {
                Toggle(isOn: .constant(sequence.userPinned)) {
                    Text("Pin ChatSequence in sidebar")
                }
            }

            Button {
                _ = chatService.autonameChatSequence(sequence, preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId)
            } label: {
                Text(appSettings.stillPopulating
                     ? "Autoname disabled (still loading)"
                     : (appSettings.preferredAutonamingModel == nil
                        ? "Autoname disabled (set a model in settings)"
                        : "Autoname with model: \(appSettings.preferredAutonamingModel!.humanId)")
                )
            }
            .disabled(appSettings.preferredAutonamingModel == nil)

            Button {
                self.isRenaming.append(sequence)
            } label: {
                Text("Rename...")
            }
        }
    }

    @ViewBuilder
    var upperToolbar: some View {
        let itemCount = self.onlyUserPinned ? maxSidebarItems : Int(maxSidebarItems * 2)

        HStack(spacing: 24) {
            Button("Refresh \(itemCount)", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(limit: itemCount, onlyUserPinned: onlyUserPinned) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Button("Refresh -- 2d", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(lookback: 172_800, onlyUserPinned: onlyUserPinned) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Button("Refresh -- 14d", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(lookback: 1_209_600, onlyUserPinned: onlyUserPinned) }
            }
            .buttonStyle(.accessoryBar)
            .lineLimit(1...3)
            .padding(12)
            .layoutPriority(0.2)

            Spacer()

            if showNewChatButton {
                NavigationLink(destination: {
                    if chatSettingsService.useSimplifiedBlankOSV {
                        BlankSimpleOneSequenceView()
                    }
                    else {
                        BlankOneSequenceView()
                    }
                }) {
                    Label("New Chat...", systemImage: "plus")
                        .buttonStyle(.accessoryBar)
                        .padding(12)
                }
                .layoutPriority(0.5)
            }
        }
    }

    func hasPendingInference(_ sequence: ChatSequence) -> Bool {
        if let existingClientModel = chatService.chatSequenceClientModels.first(where: {
            $0.sequence == sequence
        }) {
            return existingClientModel.receiving
        }

        return false
    }

    @ViewBuilder
    func sequenceRow(_ sequence: ChatSequence) -> some View {
        if self.isRenaming.contains(where: { $0 == sequence }) {
            RenameableSequenceRow(sequence, hasPending: hasPendingInference(sequence)) { newHumanDesc in
                guard newHumanDesc != sequence.humanDesc else {
                    self.isRenaming.removeAll { $0 == sequence }
                    return
                }

                print("[TRACE] Attempting rename from \(sequence.displayRecognizableDesc(replaceNewlines: true))")
                Task {
                    if let updatedSequence = await chatService.renameChatSequence(sequence, to: newHumanDesc) {
                        DispatchQueue.main.async {
                            chatService.updateSequence(withSameId: updatedSequence)
                            print("[TRACE] Finished rename to \(sequence.displayRecognizableDesc(replaceNewlines: true))")
                            self.isRenaming.removeAll { $0 == updatedSequence }
                        }
                    }
                    else {
                        DispatchQueue.main.async {
                            print("[TRACE] Failed rename to \(sequence.displayRecognizableDesc(replaceNewlines: true))")
                            self.isRenaming.removeAll { $0 == sequence }
                        }
                    }
                }
            }
        }
        else {
            SequenceRow(sequence, hasPending: hasPendingInference(sequence), showSequenceId: showSequenceIds) {
                pathHost.push(
                    chatService.clientModel(for: sequence, appSettings: appSettings, chatSettingsService: chatSettingsService)
                )
            }
        }
    }

    var body: some View {
        upperToolbar
            .padding(24)
            .font(.system(size: 18))

        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sectionedSequences(chatService.loadedChatSequences, onlyUserPinned: onlyUserPinned), id: \.0) { pair in
                        let (sectionName, sectionSequences) = pair

                        Section(content: {
                            ForEach(sectionSequences, id: \.serverId) { sequence in
                                sequenceRow(sequence)
                                    .contextMenu {
                                        sequenceContextMenu(for: sequence)
                                    }

                                Divider()
                            }
                        }, header: {
                            Text(sectionName)
                                .font(.title)
                                .monospaced()
                                .foregroundColor(.accentColor)
                                .padding(.top, 48)
                                .contextMenu {
                                    sectionContextMenu(for: sectionName, sequences: sectionSequences)
                                }

                            Divider()
                        })
                    }

                    Text("End of loaded ChatSequences")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)

                    Spacer()
                } // LazyVStack
                .padding([.leading, .trailing], 12)
            }
            .background(BackgroundEffectView().ignoresSafeArea())
            .frame(height: geometry.size.height)
        }
    }
}
