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

func sectioned(
    _ loadedChatSequences: [ChatSequence],
    includeUserPinned: Bool,
    includeLeafSequences: Bool,
    includeAll: Bool
) -> [(String, [ChatSequence])] {
    var sortedSequences = Array(loadedChatSequences)
    if !includeAll {
        sortedSequences = sortedSequences.filter {
            if includeUserPinned && $0.userPinned {
                return true
            }
            if includeLeafSequences && ($0.isLeafSequence ?? false) {
                return true
            }

            return false
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

/// TODO: Re-implement renaming
struct SequencePickerSectionView: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @Environment(AppSettings.self) public var appSettings
    @Environment(CSCSettingsService.self) public var chatSettingsService

    let sectionName: String
    let sectionSequences: [ChatSequence]
    let showSequenceIds: Bool

    @Binding private var isRenaming: [ChatSequence]

    init(
        sectionName: String,
        sectionSequences: [ChatSequence],
        showSequenceIds: Bool,
        isRenaming: Binding<[ChatSequence]>
    ) {
        self.sectionName = sectionName
        self.sectionSequences = sectionSequences
        self.showSequenceIds = showSequenceIds
        self._isRenaming = isRenaming
    }

    @ViewBuilder
    func sectionContextMenu(for sectionName: String, sequences: [ChatSequence]) -> some View {
        Text(sectionName)
            .font(.title2)
        Text("\(sequences.count) chats")

        Section(header: Text("Server-Side Chat Data")) {
            Button {
                for sequence in sequences {
                    chatService.pin(sequenceId: sequence.serverId, pinned: true)
                }
            } label: {
                Toggle(isOn: .constant(sequences.allSatisfy { $0.userPinned })) {
                    Text("Pin all to sidebar")
                }
            }
            // Disabled if everything is already pinned.
            // TODO: Figure out some set of better, less-wordy options that will do what the user wants.
            //       Seems like this'll be hard to do without analytics/user studies/more specific user personas.
            .disabled(sequences.allSatisfy { $0.userPinned })

            Button {
                for sequence in sequences {
                    chatService.pin(sequenceId: sequence.serverId, pinned: !sequence.userPinned)
                }
            } label: {
                Text("Toggle \"pinned to sidebar\" status for all")
            }
            // This is disabled if "Pin all" is the only option here, and it will do the same thing
            .disabled(sequences.allSatisfy { !$0.userPinned })

            Button {
                self.isRenaming.append(contentsOf: sequences)
            } label: {
                Text("Rename all...")
            }

            let unnamedSequenceCount: Int = sequences
                .filter { ($0.humanDesc ?? "").isEmpty }
                .count

            Button {
                // NB We intentionally run this sequentially, so rate limiting is done on the client side.
                Task {
                    for sequence in sequences {
                        if !(sequence.humanDesc ?? "").isEmpty {
                            continue
                        }

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

                Text("Autoname \(unnamedSequenceCount) unnamed sequences\n")
                + Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(.disabledControlTextColor))
            }
            .disabled(appSettings.preferredAutonamingModel == nil || unnamedSequenceCount == 0)

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
            Button {
            } label: {
                Image(systemName:
                        (sequence.isLeafSequence ?? false)
                      ? "bubble"
                      : "eye.slash")
                Text(sequence.displayRecognizableDesc())
                    .font(.title2)
            }
            .disabled(true)
        }
        else {
            Button {
            } label: {
                Image(systemName:
                        (sequence.isLeafSequence ?? false)
                      ? "bubble"
                      : "eye.slash")
                Text(sequence.humanDesc!)
                    .font(.title2)
            }
            .disabled(true)

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
                Task {
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
        Section(content: {
            ForEach(sectionSequences) { sequence in
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
}

struct SequencePickerView: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @Environment(AppSettings.self) public var appSettings
    @Environment(CSCSettingsService.self) public var chatSettingsService

    let fetchUserPinned: Bool?
    let fetchLeafSequences: Bool?
    let fetchAll: Bool?
    let showNewChatButton: Bool
    let showSequenceIds: Bool

    @State private var isRenaming: [ChatSequence] = []

    init(
        fetchUserPinned: Bool? = true,
        fetchLeafSequences: Bool? = false,
        showNewChatButton: Bool = true,
        showSequenceIds: Bool = false
    ) {
        self.fetchUserPinned = fetchUserPinned
        self.fetchLeafSequences = fetchLeafSequences
        self.fetchAll = nil
        self.showNewChatButton = showNewChatButton
        self.showSequenceIds = showSequenceIds
    }

    init(
        fetchAll: Bool?,
        showNewChatButton: Bool = true,
        showSequenceIds: Bool = false
    ) {
        self.fetchUserPinned = nil
        self.fetchLeafSequences = nil
        self.fetchAll = fetchAll
        self.showNewChatButton = showNewChatButton
        self.showSequenceIds = showSequenceIds
    }

    @ViewBuilder
    var upperToolbar: some View {
        HStack(spacing: 24) {
            Button("Refresh \(maxSidebarItems)", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(
                    limit: Int(maxSidebarItems),
                    includeUserPinned: fetchUserPinned,
                    includeLeafSequences: fetchLeafSequences,
                    includeAll: fetchAll
                ) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Button("Refresh -- 2d", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(
                    lookback: 172_800,
                    includeUserPinned: fetchUserPinned,
                    includeLeafSequences: fetchLeafSequences,
                    includeAll: fetchAll
                ) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Button("Refresh -- 14d", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(
                    lookback: 1_209_600,
                    includeUserPinned: fetchUserPinned,
                    includeLeafSequences: fetchLeafSequences,
                    includeAll: fetchAll
                ) }
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

    var body: some View {
        upperToolbar
            .padding(24)
            .font(.system(size: 18))

        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let sectionedSequences = sectioned(
                        Array(chatService.loadedChatSequences.values),
                        includeUserPinned: fetchUserPinned ?? false,
                        includeLeafSequences: fetchLeafSequences ?? false,
                        includeAll: fetchAll ?? false
                    )
                    ForEach(sectionedSequences, id: \.0) { pair in
                        let (sectionName, sectionSequences) = pair
                        SequencePickerSectionView(
                            sectionName: sectionName,
                            sectionSequences: sectionSequences,
                            showSequenceIds: showSequenceIds,
                            isRenaming: $isRenaming)
                    }

                    Text("End of loaded ChatSequences")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)

                    Spacer()
                } // VStack
                .padding([.leading, .trailing], 12)
            }
            .background(BackgroundEffectView().ignoresSafeArea())
            .frame(height: geometry.size.height)
        }
    }
}
