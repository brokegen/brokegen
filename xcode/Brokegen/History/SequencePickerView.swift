import SwiftUI

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

    init(_ sequence: ChatSequence) {
        self.sequence = sequence
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
        HStack {
            Image(systemName: "bubble")
                .font(.title)
                .padding(.leading, -8)
                .padding(.trailing, 16)

            Text(sequence.displayHumanDesc())
                .font(.title)
                .padding(.bottom, 8)
                .lineLimit(1...4)

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
                        // TODO: What we need is to dim the other rows, not brighten this one
                        .foregroundStyle(Color(.controlAccentColor))
                }
            }
        }
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

struct MiniSequencePickerSidebar: View {
    @EnvironmentObject private var chatService: ChatSyncService
    @Environment(PathHost.self) private var pathHost
    @Environment(InferenceModelSettings.self) public var inferenceModelSettings
    let navLimit: Int

    init(navLimit: Int = 2) {
        self.navLimit = navLimit
    }

    func sectionedSequences() -> [(String, [ChatSequence])] {
        let sectionedSequences = Dictionary(grouping: chatService.loadedChatSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSequences)
            .map {
                // Sorts the individual ChatSequences within a section
                ($0.0, $0.1.sorted {
                    if $0.lastMessageDate == nil {
                        return false
                    }
                    if $1.lastMessageDate == nil {
                        return true
                    }

                    return $0.lastMessageDate! > $1.lastMessageDate!
                })
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
            NavigationLink(destination: BlankOneSequenceView(
                inferenceModelSettings.defaultInferenceModel
            )) {
                HStack {
                    Image(systemName: "plus")
                        .padding(.trailing, 0)
                    Text("New")
                        .layoutPriority(0.5)
                }
                .contentShape(Rectangle())
            }
            .padding(.leading, -24)
            .padding(.trailing, -24)

            NavigationLink(destination: SequencePickerView()) {
                ASRow("Browse Recent", showChevron: true)
            }

            if !sectionedSequences().isEmpty && navLimit > 0 {
                Divider()

                ForEach(sectionedSequences().prefix(navLimit), id: \.0) { pair in
                    let (sectionName, sectionSequences) = pair

                    Section(content: {
                        ForEach(sectionSequences) { sequence in
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

                                        Spacer()

                                        if sequence.messages.count > 4 {
                                            Text("\(sequence.messages.count) messages")
                                                .lineLimit(1)
                                                .font(.system(size: 16))
                                                .foregroundStyle(Color(.disabledControlTextColor))
                                                .layoutPriority(0.2)
                                        }
                                    } // first ViewThatFits option

                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 0) {
                                            Text(sequence.displayHumanDesc())
                                                .lineLimit(1...2)
                                                .layoutPriority(0.5)
                                                .padding(.trailing, -12)

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
                                            }
                                        }
                                    } // second ViewThatFits option
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                pathHost.push(
                                    chatService.clientModel(for: sequence, inferenceModelSettings: inferenceModelSettings)
                                )
                            }
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

    private var sectionedSequences: [(String, [ChatSequence])] {
        let sectionedSequences = Dictionary(grouping: chatService.loadedChatSequences) {
            dateToSectionName($0.lastMessageDate)
        }

        return Array(sectionedSequences)
            .map {
                // Sorts the individual ChatSequences within a section
                ($0.0, $0.1.sorted {
                    if $0.lastMessageDate == nil {
                        return false
                    }
                    if $1.lastMessageDate == nil {
                        return true
                    }

                    return $0.lastMessageDate! > $1.lastMessageDate!
                })
            }
            .sorted { $0.0 > $1.0 }
    }

    var body: some View {
        HStack {
            Button("Refresh", systemImage: "arrow.clockwise") {
                chatService.fetchPinnedSequences()
            }
            .buttonStyle(.accessoryBar)
            .padding(12)

            Button("Refresh 500", systemImage: "arrow.clockwise") {
                chatService.fetchPinnedSequences(500)
            }
            .buttonStyle(.accessoryBar)
            .padding(12)

            Spacer()

            NavigationLink(destination: BlankOneSequenceView(
                inferenceModelSettings.defaultInferenceModel
            )) {
                Label("New Chat...", systemImage: "plus")
                    .buttonStyle(.accessoryBar)
                    .padding(12)
            }
        }
        .padding(24)
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
                        SequenceRow(sequence)
                            .padding(12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                pathHost.push(
                                    chatService.clientModel(for: sequence, inferenceModelSettings: inferenceModelSettings)
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
    }
}
