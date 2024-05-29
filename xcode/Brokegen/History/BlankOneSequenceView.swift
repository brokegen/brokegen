import Combine
import SwiftUI

struct ChatNameInput: View {
    @Binding var textInEdit: String
    @State var isHovered: Bool = false

    init(_ textInEdit: Binding<String>) {
        _textInEdit = textInEdit
    }

    var body: some View {
        TextField("Enter a chat name", text: $textInEdit, axis: .vertical)
            .font(.system(size: 72))
            .textFieldStyle(.plain)
            .monospaced()
            .lineSpacing(240)
            .background(
                isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
            )
            .onHover { isHovered in
                self.isHovered = isHovered
            }
            .padding(6)
            .padding(.top, 48)
            // Draws a single baseline bar at the bottom of the control
            .overlay(
                Divider().background(Color.accentColor), alignment: .bottom
            )
    }
}

struct InlineTextInput: View {
    @Binding var textInEdit: String
    @State var isHovered: Bool = false
    /// Crossover length where we swap implementations to a TextEditor
    let textFieldMaxChars: Int

    init(
        _ textInEdit: Binding<String>,
        textFieldMaxChars: Int = 280
    ) {
        _textInEdit = textInEdit
        self.textFieldMaxChars = textFieldMaxChars
    }

    var body: some View {
        if textInEdit.count <= textFieldMaxChars {
            TextField("Enter your message", text: $textInEdit, axis: .vertical)
                .textFieldStyle(.plain)
                .lineSpacing(240)
                .monospaced()
                .lineLimit(4...40)
                .background(
                    isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
                )
                .onHover { isHovered in
                    self.isHovered = isHovered
                }
                .padding(6)
        }
        else {
            TextEditor(text: $textInEdit)
                .scrollDisabled(true)
                .monospaced()
                .lineLimit(4...40)
                .background(
                    isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
                )
                .onHover { isHovered in
                    self.isHovered = isHovered
                }
                .padding(6)
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
            guard messageId != nil else { return }

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

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 72) {
                ChatNameInput($chatSequenceHumanDesc)
                    .frame(maxWidth: .infinity)
                    .padding(24)

                Text("Starting a new chat")
                    .foregroundStyle(.secondary)
                    .font(.title)
            }

            Spacer()

            HStack {
                InlineTextInput($promptInEdit)
                    .disabled(submitting)
                    .onSubmit {
                        // TODO: This only works when in TextField mode; TextEditor eats the Enter key.
                        print("[DEBUG] BlankOSV submitting prompt from TextField: \(promptInEdit)")
                        submit()
                    }

                VStack {
                    Button(action: stopSubmitAndReceive) {
                        Image(systemName: submitting ? "stop.fill" : "stop")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(!submitting)
                    }
                    .buttonStyle(.plain)
                    .help("Stop submitting or receiving")

                    Spacer()

                    Button(action: submit) {
                        Image(systemName: submitting ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(submitting)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
                .padding(.leading, 12)
                .padding(.trailing, -12)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .frame(maxHeight: 800)
    }
}
