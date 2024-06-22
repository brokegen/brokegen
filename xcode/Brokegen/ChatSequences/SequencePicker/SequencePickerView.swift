import SwiftUI

let maxSidebarItems = 10

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

fileprivate func dateToISOWeekStartingMonday(_ date: Date) -> String {
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

extension ChatSequence {
    func displayHumanDesc() -> String {
        if !(humanDesc ?? "").isEmpty {
            return humanDesc!
        }

        return "ChatSequence#\(serverId!)"
    }
}

struct SequenceRow: View {
    @Environment(ProviderService.self) private var providerService

    let sequence: ChatSequence
    let action: (() -> Void)

    @State private var isLoading: Bool = false

    init(_ sequence: ChatSequence, action: @escaping () -> Void) {
        self.sequence = sequence
        self.action = action
    }

    func displayDate() -> String? {
        if let date = sequence.lastMessageDate {
            return dateToISOWeekStartingMonday(date) + " " + date.formatted(date: .omitted, time: .standard)
        }
        else {
            return nil
        }
    }

    func displayInferenceModel() -> String? {
        guard sequence.inferenceModelId != nil else { return nil }

        if let model = providerService.allModels.first(where: {
            $0.serverId == sequence.inferenceModelId!
        }) {
            return model.humanId
        }
        return nil
    }

    var body: some View {
        Button(action: {
            isLoading = true
            action()
        }, label: {
            HStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: sequence.userPinned
                          ? "bubble"
                          : "eye.slash")

                    Text(sequence.displayHumanDesc())
                        .lineLimit(1...4)
                        .multilineTextAlignment(.leading)
                }
                .font(.title)
                .padding(12)
                .padding(.leading, -8)
                .foregroundStyle(
                    sequence.userPinned
                    ? Color(.controlTextColor)
                    : Color(.disabledControlTextColor)
                )

                Spacer()

                VStack(alignment: .trailing) {
                    if let displayDate = displayDate() {
                        Text(displayDate)
                            .monospaced()
                    }

                    Text("\(sequence.messages.count) messages")

                    if let modelName = displayInferenceModel() {
                        Spacer()

                        Text(modelName)
                            .monospaced()
                            .foregroundStyle(Color(.controlAccentColor).opacity(0.6))
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
        })
        .buttonStyle(.borderless)
    }
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
    @Environment(PathHost.self) private var pathHost
    @EnvironmentObject public var appSettings: AppSettings
    @EnvironmentObject public var chatSettingsService: CSCSettingsService

    let onlyUserPinned: Bool

    init(onlyUserPinned: Bool = true) {
        self.onlyUserPinned = onlyUserPinned
    }

    private var sectionedSequences: [(String, [ChatSequence])] {
        var sortedSequences = chatService.loadedChatSequences
        if onlyUserPinned {
            sortedSequences = sortedSequences.filter { $0.userPinned == true }
        }
        sortedSequences = sortedSequences.sorted()

        let sectionedSequences = Dictionary(grouping: sortedSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSequences)
            // DEBUG: This should be redundant with the above .sorted(), removing for now
//            .map {
//                // Sorts the individual ChatSequences within a section
//                ($0.0, $0.1.sorted())
//            }
            .sorted { $0.0 > $1.0 }
    }

    var body: some View {
        HStack(spacing: 24) {
            Button("Refresh \(maxSidebarItems * 5)", systemImage: "arrow.clockwise") {
                Task { try? await chatService.fetchRecents(limit: maxSidebarItems * 5, onlyUserPinned: onlyUserPinned) }
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
            .padding(12)
            .layoutPriority(0.2)

            Spacer()

            if chatSettingsService.useSimplifiedSequenceViews {
                NavigationLink(destination: {
                    BlankOneSequenceView()
                }) {
                    Label("New Chat...", systemImage: "plus")
                        .buttonStyle(.accessoryBar)
                        .padding(12)
                }
                .layoutPriority(0.5)
            }
            else {
                NavigationLink(destination: {
                    ProSequenceView(
                        OneSequenceViewModel.createBlank(chatService: chatService, appSettings: appSettings, chatSettingsService: chatSettingsService)
                    )
                }) {
                    Label("New Chat (experimental)", systemImage: "plus")
                        .buttonStyle(.accessoryBar)
                        .padding(12)
                }
                .layoutPriority(0.5)
            }
        }
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
                ) {
                    ForEach(sectionSequences, id: \.serverId) { sequence in
                        SequenceRow(sequence) {
                            pathHost.push(
                                chatService.clientModel(for: sequence, appSettings: appSettings, chatSettingsService: chatSettingsService)
                            )
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
