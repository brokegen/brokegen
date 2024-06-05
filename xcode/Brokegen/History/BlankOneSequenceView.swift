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
    @Environment(InferenceModelSettings.self) public var inferenceModelSettings

    @State var modelSelection: InferenceModel?
    @State var showModelPicker: Bool

    @State var chatSequenceHumanDesc: String = ""
    @State var promptInEdit: String = ""
    @State var submitting: Bool = false

    @FocusState var focusTextInput: Bool

    init(_ initialModel: InferenceModel? = nil) {
        if initialModel == nil {
            _showModelPicker = State(initialValue: true)
        }
        else {
            _showModelPicker = State(initialValue: false)
            self.modelSelection = initialModel
        }
    }

    var body: some View {
        VStack {
            ChatNameInput($chatSequenceHumanDesc)
                .frame(maxWidth: .infinity)
                .padding(24)

            // Display the model info, because otherwise there's nothing to see
            if modelSelection != nil {
                OneInferenceModelView(model: modelSelection!, modelAvailable: true, modelSelection: $modelSelection, enableModelSelection: false)
                    .frame(maxWidth: 800)
                    .layoutPriority(0.2)
            }
            else if inferenceModelSettings.defaultInferenceModel != nil {
                OneInferenceModelView(model: inferenceModelSettings.defaultInferenceModel!, modelAvailable: true, modelSelection: $modelSelection, enableModelSelection: false)
                    .frame(maxWidth: 800)
                    .layoutPriority(0.2)
            }
            else {
                let finalDesc: String = {
                    if let humanDesc: String = inferenceModelSettings.fallbackInferenceModel?.humanId {
                        return "No model selected, will fallback to \(humanDesc)"
                    }
                    else {
                        return "No model selected"
                    }
                }()
                Text(finalDesc)
            }

            VStack {
                Spacer()
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Text(submitting ? "Submitting ChatMessage/Sequence" : "Ready")
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
                .help("RAG not available in this view")

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
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(modelSelection: $modelSelection)
                .frame(width: 800, height: 1200, alignment: .top)
                .animation(.linear(duration: 0.2))
        }
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
                print("[ERROR] Couldn't submit message: \(promptInEdit)")
                return
            }

            let sequenceId: ChatSequenceServerID? =
                await constructUserSequence(id: messageId!)
            guard sequenceId != nil else {
                submitting = false
                print("[ERROR] Couldn't construct sequence from: ChatMessage#\(messageId!)")
                return
            }

            let nextSequence = await chatService.fetchSequence(sequenceId!)
            guard nextSequence != nil else {
                submitting = false
                print("[ERROR] Couldn't fetch sequence information for ChatSequence#\(sequenceId!)")
                return
            }

            pathHost.push(
                chatService.clientModel(for: nextSequence!, inferenceModelSettings: inferenceModelSettings)
                    .requestContinue(model: modelSelection!.serverId)
                )
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }
}
