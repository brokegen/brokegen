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

func sectionedSequences(
    _ loadedChatSequences: [ChatSequence],
    onlyUserPinned: Bool
) -> [(String, [ChatSequence])] {
    var sortedSequences = Array(loadedChatSequences)
    if onlyUserPinned {
        sortedSequences = sortedSequences.filter {
            $0.userPinned == true || $0.isLeafSequence == true
        }
    }
    sortedSequences = sortedSequences.sorted()

    let sectionedSequences = Dictionary(grouping: sortedSequences) {
        dateToSectionName($0.generatedAt)
    }

    let result = Array(sectionedSequences)
        .sorted { $0.0 > $1.0 }

    return result
}

// MARK: - actual SequencePicker
struct SequencePickerView: View {
    @EnvironmentObject private var chatService: ChatSyncService
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
        Text(sectionName)
            .font(.title2)
        Text("\(sequences.count) chats")

        Section(header: Text("Server-Side Chat Data")) {
            Button {
                for sequence in sequences {
                    chatService.pin(sequenceId: sequence.serverId, pinned: !sequence.userPinned)
                }
            } label: {
                Text("Pin all to sidebar")
            }

            Button {
                self.isRenaming.append(contentsOf: sequences)
            } label: {
                Text("Rename all...")
            }

            Button {
                // NB We intentionally run this sequentially, so rate limiting is done on the client side.
                Task { @MainActor in
                    for sequence in sequences {
                        _ = try? await chatService.autonameBlocking(sequenceId: sequence.serverId, preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId)
                    }
                }
            } label: {
                let subtitle: String = {
                    appSettings.preferredAutonamingModel == nil
                    ? (appSettings.stillPopulating
                       ? "disabled, still loading"
                       : "disabled, set a model in settings")
                    : "\(appSettings.preferredAutonamingModel!)"
                }()

                Text("Autoname all\n")
                + Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(.disabledControlTextColor))
            }
            .disabled(appSettings.preferredAutonamingModel == nil)

            Divider()

            Button {
                Task {
                    for sequence in sequences {
                        if let refreshedSequence = try? await chatService.fetchChatSequenceDetails(sequence.serverId) {
                            DispatchQueue.main.sync {
                                self.chatService.updateSequence(withSameId: refreshedSequence)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                Text("Refresh all sequence data from server")
            }
        }
    }

    @ViewBuilder
    func sequenceContextMenu(for sequence: ChatSequence) -> some View {
        if (sequence.humanDesc ?? "").isEmpty {
            Text(sequence.displayRecognizableDesc())
                .font(.title2)
        }
        else {
            Text(sequence.humanDesc!)
                .font(.title2)
            Text(sequence.displayServerId())
        }

        Section(header: Text("Server-Side Chat Data")) {
            Button {
                chatService.pin(sequenceId: sequence.serverId, pinned: !sequence.userPinned)
            } label: {
                Toggle(isOn: .constant(sequence.userPinned)) {
                    Text("Pin to sidebar")
                }
            }

            Button {
                self.isRenaming.append(sequence)
            } label: {
                Text("Rename...")
            }

            Button {
                Task { @MainActor in
                    _ = try? await chatService.autonameBlocking(sequenceId: sequence.serverId, preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId)
                }
            } label: {
                let subtitle: String = {
                    appSettings.preferredAutonamingModel == nil
                    ? (appSettings.stillPopulating
                       ? "disabled, still loading"
                       : "disabled, set a model in settings")
                    : "\(appSettings.preferredAutonamingModel!)"
                }()

                Text("Autoname\n")
                + Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(.disabledControlTextColor))
            }
            .disabled(appSettings.preferredAutonamingModel == nil)

            Divider()

            Button {
                Task {
                    if let refreshedSequence = try? await chatService.fetchChatSequenceDetails(sequence.serverId) {
                        DispatchQueue.main.async {
                            self.chatService.updateSequence(withSameId: refreshedSequence)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                Text("Refresh sequence data from server")
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
                .frame(minWidth: 0)

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
                print("[TRACE] Attempting rename from \(sequence.displayRecognizableDesc(replaceNewlines: true))")
                if let updatedSequence = try? await chatService.renameBlocking(sequenceId: sequence.serverId, to: newHumanDesc) {
                }
                else {
                    print("[TRACE] Failed rename to \(sequence.displayRecognizableDesc(replaceNewlines: true))")
                }

                self.isRenaming.removeAll { $0.serverId == sequence.serverId }
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
                    ForEach(sectionedSequences(Array(chatService.loadedChatSequences.values), onlyUserPinned: onlyUserPinned), id: \.0) { pair in
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
                                    if sectionSequences.count == 1 {
                                        sequenceContextMenu(for: sectionSequences.first!)
                                    }
                                    else {
                                        sectionContextMenu(for: sectionName, sequences: sectionSequences)
                                    }
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
