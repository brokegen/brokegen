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
                    Image(systemName: "bubble")
                        .font(.title)

                    Text(sequence.displayHumanDesc())
                        .font(.title)
                        .lineLimit(1...4)
                        .foregroundStyle(Color(.controlTextColor).opacity(0.8))
                }
                .foregroundStyle(Color(.controlTextColor))
                .padding(12)
                .padding(.leading, -8)

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

struct MiniSequencePickerSidebar: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @Environment(InferenceModelSettings.self) public var inferenceModelSettings
    @EnvironmentObject public var chatSettingsService: CSCSettingsService
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
            NavigationLink(destination: {
                // TODO: Figure out how to re-pop up the model chooser if we click this link again
                BlankOneSequenceView(inferenceModelSettings.defaultInferenceModel)
            }) {
                HStack {
                    Image(systemName: "plus")
                        .padding(.trailing, 0)
                        .layoutPriority(0.2)
                    Text("New")
                        .layoutPriority(0.5)

                    Spacer()
                }
                .contentShape(Rectangle())
                .foregroundStyle(Color.accentColor)
            }
            .padding(.leading, -24)
            .padding(.trailing, -24)
            .frame(maxWidth: .infinity)

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
                        ForEach(sectionSequences) { sequence in
                            Button(action: {
                                pathHost.push(
                                    chatService.clientModel(for: sequence, inferenceModelSettings: inferenceModelSettings, chatSettingsService: chatSettingsService)
                                )
                            }, label: {
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
}

struct SequencePickerView: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @Environment(InferenceModelSettings.self) public var inferenceModelSettings
    @EnvironmentObject public var chatSettingsService: CSCSettingsService

    private var sectionedSequences: [(String, [ChatSequence])] {
        let sectionedSequences = Dictionary(grouping: chatService.loadedChatSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSequences)
            .map {
                // Sorts the individual ChatSequences within a section
                ($0.0, $0.1.sorted())
            }
            .sorted { $0.0 > $1.0 }
    }

    var body: some View {
        HStack(spacing: 24) {
            Button("Refresh \(maxSidebarItems)", systemImage: "arrow.clockwise") {
                Task { try? await chatService.refreshPinnedChatSequences(limit: maxSidebarItems) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Button("Refresh -- 2d", systemImage: "arrow.clockwise") {
                Task { try? await chatService.refreshPinnedChatSequences(lookback: 172_800) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Button("Refresh -- 14d", systemImage: "arrow.clockwise") {
                Task { try? await chatService.refreshPinnedChatSequences(lookback: 1_209_600) }
            }
            .buttonStyle(.accessoryBar)
            .padding(12)
            .layoutPriority(0.2)

            Spacer()

            NavigationLink(destination: BlankOneSequenceView(
                inferenceModelSettings.defaultInferenceModel
            )) {
                Label("New Chat...", systemImage: "plus")
                    .buttonStyle(.accessoryBar)
                    .padding(12)
            }
            .layoutPriority(0.5)
        }
        .padding(24)
        .font(.system(size: 18))
        .frame(maxWidth: 1000)

        List {
            ForEach(sectionedSequences, id: \.0) { pair in
                let (sectionName, sectionSequences) = pair

                Section(header: Text(sectionName)
                    .font(.title)
                    .monospaced()
                    .foregroundColor(.accentColor)
                    .padding(.top, 36)
                ) {
                    ForEach(sectionSequences) { sequence in
                        SequenceRow(sequence) {
                            pathHost.push(
                                chatService.clientModel(for: sequence, inferenceModelSettings: inferenceModelSettings, chatSettingsService: chatSettingsService)
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
