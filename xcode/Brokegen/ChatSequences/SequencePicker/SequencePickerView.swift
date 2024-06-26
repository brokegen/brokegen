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

func dateToSectionName(_ date: Date?) -> String {
    // NB This "default" name should sort later than the ones starting 2024-wwXX
    guard date != nil else { return "0000 no date" }

    let sectionName = dateToISOWeekStartingMonday(date!)

    // If the date was more than a week ago, just return the week-name
    if date!.timeIntervalSinceNow < -168 * 24 * 3600 {
        return String(sectionName.prefix(9))
    }

    // If it's in the previous week, truncate so it's just the week-name
    let todaySection = dateToISOWeekStartingMonday(Date.now)
    if sectionName.prefix(9) != todaySection.prefix(9) {
        return String(sectionName.prefix(9))
    }

    return sectionName
}

extension ChatSequence: Comparable {
    static func < (lhs: ChatSequence, rhs: ChatSequence) -> Bool {
        if lhs.lastMessageDate == nil {
            return false
        }
        if rhs.lastMessageDate == nil {
            return true
        }

        return lhs.lastMessageDate! > rhs.lastMessageDate!
    }
}

struct SequencePickerView: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @EnvironmentObject private var pathHost: PathHost
    @EnvironmentObject public var appSettings: AppSettings
    @EnvironmentObject public var chatSettingsService: CSCSettingsService

    let onlyUserPinned: Bool
    let showNewChatButton: Bool

    @State private var isRenaming: [ChatSequence] = []

    init(onlyUserPinned: Bool = true, showNewChatButton: Bool = true) {
        self.onlyUserPinned = onlyUserPinned
        self.showNewChatButton = showNewChatButton
    }

    private var sectionedSequences: [(String, [ChatSequence])] {
        var sortedSequences = chatService.loadedChatSequences
        if onlyUserPinned {
            sortedSequences = sortedSequences.filter {
                $0.userPinned == true || $0.isLeafSequence == true
            }
        }
        sortedSequences = sortedSequences.sorted()

        let sectionedSequences = Dictionary(grouping: sortedSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSequences)
            .sorted { $0.0 > $1.0 }
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
                let updatedSequence = chatService.pinChatSequence(sequence, pinned: !sequence.userPinned)
                chatService.updateSequence(withSameId: updatedSequence)
            } label: {
                Toggle(isOn: .constant(sequence.userPinned)) {
                    Text("Pin ChatSequence to sidebar")
                }
            }

            Button {
                _ = chatService.autonameChatSequence(sequence, preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId)
            } label: {
                Text(appSettings.stillPopulating
                     ? "Autoname disabled (still loading)"
                     : (appSettings.preferredAutonamingModel == nil
                        ? "Autoname disabled (set a model in settings)"
                        : "Autoname chat with \(appSettings.preferredAutonamingModel!.humanId)")
                )
            }
            .disabled(appSettings.preferredAutonamingModel == nil)

            Button {
                self.isRenaming.append(sequence)
            } label: {
                Text("Rename (experimental)...")
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
                        BlankOneSequenceView()
                    }
                    else {
                        BlankProSequenceView()
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

    @ViewBuilder
    func sequenceRow(_ sequence: ChatSequence) -> some View {
        if self.isRenaming.contains(where: { $0 == sequence }) {
            RenameableSequenceRow(sequence) {
                let updatedSequence = chatService.renameChatSequence(sequence, to: $0)
                chatService.updateSequence(withSameId: updatedSequence)

                self.isRenaming.removeAll { $0 == sequence }
            }
        }
        else {
            SequenceRow(sequence) {
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

        List {
            ForEach(sectionedSequences, id: \.0) { pair in
                let (sectionName, sectionSequences) = pair

                Section(header: Text(sectionName)
                    .font(.title)
                    .monospaced()
                    .foregroundColor(.accentColor)
                    .padding(.top, 36)
                    .contextMenu {
                        sectionContextMenu(for: sectionName, sequences: sectionSequences)
                    }
                ) {
                    ForEach(sectionSequences, id: \.serverId) { sequence in
                        sequenceRow(sequence)
                            .contextMenu {
                                sequenceContextMenu(for: sequence)
                            }
                    }
                }
                .padding(8)
            }

            Text("End of loaded ChatSequences")
                .foregroundStyle(Color(.disabledControlTextColor))
                .frame(height: 400)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
