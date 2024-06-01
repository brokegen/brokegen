import Combine
import SwiftUI

struct ChatNameInput: View {
    @Binding var textInEdit: String
    @State var isHovered: Bool = false

    init(_ textInEdit: Binding<String>) {
        _textInEdit = textInEdit
    }

    var body: some View {
        TextField("", text: $textInEdit, axis: .vertical)
            .font(.system(size: 72))
            .textFieldStyle(.plain)
            .monospaced()
            .lineSpacing(240)
            .lineLimit(1...2)
            .background(
                isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
            )
            .onHover { isHovered in
                self.isHovered = isHovered
            }
            .padding(.bottom, 12)
            // Draws a single baseline bar at the bottom of the control
            .overlay(
                Divider().background(Color.accentColor), alignment: .bottom
            )
    }
}

struct InlineTextInput: View {
    @Binding var textInEdit: String
    var isFocused: FocusState<Bool>.Binding
    @State var isHovered: Bool = false

    /// Crossover length where we swap implementations to a TextEditor
    let textFieldMaxChars: Int

    init(
        _ textInEdit: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        textFieldMaxChars: Int = 280
    ) {
        _textInEdit = textInEdit
        self.isFocused = isFocused
        self.textFieldMaxChars = textFieldMaxChars
    }

    var body: some View {
        ZStack {
            if textInEdit.count <= textFieldMaxChars {
                TextField("Enter your message", text: $textInEdit, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineSpacing(6)

                // Shared styling starts here; duplicated because it's only two entries
                // and this we don't have to worry about type erasure that comes with ViewModifiers.
                    .monospaced()
                    .lineLimit(8...40)
                    .padding(6)
                    .onHover { isHovered in
                        self.isHovered = isHovered
                    }
                    .focused(isFocused, equals: true)
                    .background(isHovered ? Color(.selectedControlColor) : Color(.controlBackgroundColor))
            }
            else {
                // TODO: TextEditor eats the Enter key when submitting.
                TextEditor(text: $textInEdit)
                    .lineSpacing(6)

                // Shared styling starts here; duplicated because it's only two entries
                // and this we don't have to worry about type erasure that comes with ViewModifiers.
                    .monospaced()
                    .lineLimit(8...40)
                    .padding(6)
                    .onHover { isHovered in
                        self.isHovered = isHovered
                    }
                    .focused(isFocused, equals: true)
                    .background(isHovered ? Color(.selectedControlColor) : Color(.controlBackgroundColor))
            }
        }
    }
}

struct BlankOneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    @Environment(PathHost.self) private var pathHost
    let initialModel: InferenceModel

    @State var chatSequenceHumanDesc: String = ""
    @State var promptInEdit: String = ""
    @State var submitting: Bool = false

    @FocusState var focusTextInput: Bool

    init(_ initialModel: InferenceModel) {
        self.initialModel = initialModel
    }

    private func prettyDate(_ requestedDate: Date? = nil) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions.insert(.withFractionalSeconds)

        let date = requestedDate ?? Date.now
        return dateFormatter.string(from: date)
    }

    private func constructUserSequence(id messageID: ChatMessageServerID) async -> ChatSequenceServerID? {
        struct Parameters: Codable {
            var humanDesc: String? = nil
            var userPinned: Bool
            let currentMessage: ChatMessageServerID
            var parentSequence: ChatSequenceServerID? = nil
            var generatedAt: String?
            var generationComplete: Bool
            var inferenceJobId: InferenceEventID? = nil
            var inferenceError: String? = nil
        }
        let params = Parameters(
            humanDesc: chatSequenceHumanDesc,
            userPinned: true,
            currentMessage: messageID,
            generatedAt: prettyDate(),
            generationComplete: true
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            let jsonDict = try await chatService.postData(
                try encoder.encode(params),
                endpoint: "/sequences")
            guard jsonDict != nil else { return nil }

            let sequenceID: ChatMessageServerID? = jsonDict!["sequence_id"] as? Int
            return sequenceID
        }
        catch {
            return nil
        }
    }

    func submit() {
        Task.init {
            submitting = true

            let messageId: ChatMessageServerID? = await chatService.constructUserMessage(promptInEdit)
            guard messageId != nil else {
                submitting = false
                return
            }

            let sequenceId: ChatSequenceServerID? =
                await constructUserSequence(id: messageId!)

            if sequenceId != nil {
                let nextSequence = await chatService.fetchSequence(sequenceId!)
                pathHost.push(ChatSequenceParameters(
                    nextMessage: nil,
                    sequenceId: sequenceId!,
                    sequence: nextSequence,
                    continuationModelId: initialModel.serverId))
            }
            else {
                print("[ERROR] Couldn't push next ChatSequenceParameters onto NavigationStack")
            }
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }

    private func formatJson(_ jsonDict: [String : Any], indent: Int = 0) -> String {
        var stringMaker = ""
        for (k, v) in jsonDict {
            if v != nil {
                stringMaker += String(repeating: " ", count: indent)
                stringMaker += "\(k): \(v)\n"
            }
        }

        return stringMaker
    }

    var body: some View {
        VStack {
            ChatNameInput($chatSequenceHumanDesc)
                .frame(maxWidth: .infinity)
                .padding(24)

            // Display the model info, because otherwise there's nothing to see
            VStack(alignment: .leading) {
                Text(initialModel.humanId)
                    .font(.title)
                    .monospaced()
                    .foregroundColor(.accentColor)
                    .lineLimit(2)
                    .padding(.bottom, 8)

                if let lastSeen = initialModel.lastSeen {
                    Text("Last seen: " + String(describing: lastSeen))
                        .font(.subheadline)
                }

                Divider()

                Group {
                    if initialModel.stats != nil {
                        Text("stats: \n" + formatJson(initialModel.stats!, indent: 2))
                            .lineLimit(1...)
                            .monospaced()
                            .padding(4)
                    }

                    Text(formatJson(initialModel.modelIdentifiers!))
                        .lineLimit(1...)
                        .monospaced()
                        .padding(4)
                }
            }
            .padding(12)
            .listRowSeparator(.hidden)
            .padding(.bottom, 48)
            .frame(maxWidth: 800)
            .layoutPriority(0.2)

            VStack {
                Spacer()
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Text("Starting a new chat")
                    .foregroundStyle(Color(.disabledControlTextColor))

                Spacer()

                if submitting {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 120)
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 24)

            HStack {
                InlineTextInput($promptInEdit, isFocused: $focusTextInput)
                    .focused($focusTextInput)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.focusTextInput = true
                        }
                    }
                    .backgroundStyle(inputBackgroundStyle)

                Button(action: stopSubmitAndReceive) {
                    Image(systemName: submitting ? "stop.fill" : "stop")
                        .font(.system(size: 32))
                        .disabled(!submitting)
                        .foregroundStyle(!submitting ? Color(.disabledControlTextColor) : Color(.controlTextColor))
                }
                .buttonStyle(.plain)
                .help("Stop submitting or receiving")
                .padding(.leading, 12)

                Button(action: submit) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 32))
                        .disabled(true)
                        .foregroundStyle(true ? Color(.disabledControlTextColor) : Color(.controlTextColor))
                }
                .buttonStyle(.plain)
                .help("Submit with Retrieval-Augmented Generation")

                Button(action: submit) {
                    Image(systemName: submitting ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 32))
                        .disabled(submitting)
                        .foregroundStyle(submitting ? Color(.disabledControlTextColor) : Color(.controlTextColor))
                }
                .buttonStyle(.plain)
                .help("Submit")
            }
            .padding(.trailing, 12)
            .background(inputBackgroundStyle)
        }
        .frame(maxHeight: .infinity)
        .onTapGesture {
            focusTextInput = true
        }
    }
}
