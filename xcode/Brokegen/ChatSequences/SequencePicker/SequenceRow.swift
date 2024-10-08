import SwiftUI

struct SequenceRow: View {
    @Environment(ProviderService.self) private var providerService

    let sequence: ChatSequence
    let hasPending: Bool
    let showSequenceId: Bool
    let action: (() -> Void)

    init(
        _ sequence: ChatSequence,
        hasPending: Bool = false,
        showSequenceId: Bool = false,
        action: @escaping () -> Void
    ) {
        self.sequence = sequence
        self.hasPending = hasPending
        self.showSequenceId = showSequenceId
        self.action = action
    }

    func displayDate() -> String? {
        if let date = sequence.generatedAt {
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
            // TODO: This probably does not need to be wrapped in a Task(), but we'd need to audit callers to confirm.
            Task { @MainActor in
                action()
            }
        }, label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        if sequence.userPinned {
                            Image(systemName: "pin.fill")
                        }

                        if sequence.isLeafSequence ?? false {
                            Image(systemName: "bubble")
                        }
                        else {
                            Image(systemName: "eye.slash")
                                .foregroundStyle(Color(.disabledControlTextColor))
                        }

                        Text(showSequenceId ? sequence.displayRecognizableDesc() : sequence.displayHumanDesc())
                            .lineLimit(1...4)
                            .multilineTextAlignment(.leading)
                    }
                    .font(.title)
                    .padding(.leading, -8)
                    .foregroundStyle(
                        sequence.userPinned || (sequence.isLeafSequence ?? false)
                        ? Color(.controlTextColor)
                        : Color(.disabledControlTextColor)
                    )

                    // MARK: - Details shown under sequence name/header
                    if showSequenceId && sequence.parentSequences != nil {
                        Text(String(describing: sequence.parentSequences!))
                            .monospaced()
                            .foregroundStyle(Color(.disabledControlTextColor))
                            .multilineTextAlignment(.leading)
                    }

                    if showSequenceId && sequence.parentSequences != nil && !sequence.messages.isEmpty {
                        Divider()
                            .opacity(0.2)
                    }

                    if !sequence.messages.isEmpty {
                        Text(String(describing: sequence.messages.last!.content))
                            .lineLimit(1...4)
                            .foregroundStyle(Color(.disabledControlTextColor))
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(12)

                Spacer()

                VStack(alignment: .trailing) {
                    if let displayDate = displayDate() {
                        Text(displayDate)
                            .monospaced()
                    }

                    Text(sequence.parentSequences != nil
                         ? "\(sequence.parentSequences!.count) chat messages"
                         : "\(sequence.messages.count) info + chat messages")

                    if hasPending {
                        Text("+1 pending response")
                    }

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

struct RenameableSequenceRow: View {
    @Environment(ProviderService.self) private var providerService

    let sequence: ChatSequence
    let hasPending: Bool
    @State private var newSequenceName: String
    let action: ((String) async -> Void)

    @FocusState private var isFocused: Bool
    @State private var isHovered: Bool = false

    init(
        _ sequence: ChatSequence,
        hasPending: Bool = false,
        action: @escaping (String) async -> Void
    ) {
        self.sequence = sequence
        self.hasPending = hasPending
        self.newSequenceName = sequence.humanDesc ?? ""
        self.action = action
    }

    func displayDate() -> String? {
        if let date = sequence.generatedAt {
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    if sequence.userPinned {
                        Image(systemName: "pin.fill")
                            .padding([.top, .bottom], 12)
                    }

                    if sequence.isLeafSequence ?? false {
                        Image(systemName: "bubble")
                            .padding([.top, .bottom], 12)
                    }
                    else {
                        Image(systemName: "eye.slash")
                            .padding([.top, .bottom], 12)
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    HStack(spacing: 0) {
                        TextField("", text: $newSequenceName, axis: .vertical)
                            .lineLimit(1...30)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                            .background(
                                Rectangle()
                                    .fill(Color.clear)
                                    .strokeBorder(lineWidth: 4)
                                    .foregroundColor(Color(.selectedControlColor))
                                    .opacity(isHovered ? 1.0 : 0.0)
                            )
                            .padding(.leading, -12)
                            .focused($isFocused)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    self.isFocused = true
                                }
                            }
                            .onSubmit {
                                Task { @MainActor in
                                    await action(newSequenceName)
                                }
                            }

                        Image(systemName: "pencil")
                            .padding(12)
                    }
                    .background(Color(.controlBackgroundColor))
                }
                .font(.title)
                .padding(.leading, 4)
                .onHover { isHovered in
                    self.isHovered = isHovered
                }
                .foregroundStyle(
                    sequence.userPinned || (sequence.isLeafSequence ?? false)
                    ? Color(.controlTextColor)
                    : Color(.disabledControlTextColor)
                )
            }

            Spacer()

            VStack(alignment: .trailing) {
                if let displayDate = displayDate() {
                    Text(displayDate)
                        .monospaced()
                }

                Text(sequence.parentSequences != nil
                     ? "\(sequence.parentSequences!.count) chat messages"
                     : "\(sequence.messages.count) info + chat messages")

                if hasPending {
                    Text("+1 pending response")
                }

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
    }
}

