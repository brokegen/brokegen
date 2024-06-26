import SwiftUI

struct SequenceRow: View {
    @EnvironmentObject private var providerService: ProviderService

    let sequence: ChatSequence
    let action: (() -> Void)

    init(
        _ sequence: ChatSequence,
        action: @escaping () -> Void
    ) {
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
            action()
        }, label: {
            HStack(spacing: 0) {
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

                    Text(sequence.displayHumanDesc())
                        .lineLimit(1...4)
                        .multilineTextAlignment(.leading)
                }
                .font(.title)
                .padding(12)
                .padding(.leading, -8)
                .foregroundStyle(
                    sequence.userPinned || (sequence.isLeafSequence ?? false)
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

struct RenameableSequenceRow: View {
    @EnvironmentObject private var providerService: ProviderService

    let sequence: ChatSequence
    @State private var newSequenceName: String
    let action: ((String) -> Void)

    @FocusState private var isFocused: Bool
    @State private var isHovered: Bool = false

    init(
        _ sequence: ChatSequence,
        action: @escaping (String) -> Void
    ) {
        self.sequence = sequence
        self.newSequenceName = sequence.humanDesc ?? ""
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
        HStack(spacing: 0) {
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
                    TextField("", text: $newSequenceName)
                        .lineLimit(1...4)
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
                            action(newSequenceName)
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
    }
}

