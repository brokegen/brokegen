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

struct BlankOneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    let model: InferenceModel

    @State var chatHumanDesc: String = ""
    @State var promptInEdit: String = ""
    @State var submitting: Bool = false

    init(_ model: InferenceModel) {
        self.model = model
    }

    func submit() {
        Task.init {
            /// TODO: Figure out how to avoid race conditions and run this only once
            submitting = true
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 72) {
                ChatNameInput($chatHumanDesc)
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
                        submit()
                    }

                VStack {
                    Button(action: stopSubmitAndReceive) {
                        Image(systemName: submitting ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(!submitting)
                    }
                    .buttonStyle(.plain)
                    .help("Stop submitting or receiving")
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
