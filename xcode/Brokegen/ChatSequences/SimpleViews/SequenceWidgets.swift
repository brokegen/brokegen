import SwiftUI

let inputBackgroundStyle = Color(.controlBackgroundColor)

struct ForegroundAccentColor: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .foregroundStyle(Color.accentColor)
        }
        else {
            content
        }
    }
}

struct BackgroundEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()

        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground

        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        //
    }
}

struct ChatNameReadOnly: View {
    @Binding var textInEdit: String
    @Binding var pinChatSequenceDesc: Bool

    init(_ textInEdit: Binding<String>, pinChatName: Binding<Bool>) {
        _textInEdit = textInEdit
        _pinChatSequenceDesc = pinChatName
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(textInEdit)
                .font(.system(size: 36))
                .foregroundColor(.gray)
                .lineLimit(1...10)
                .layoutPriority(0.2)

            Spacer()

            Button(action: {
                pinChatSequenceDesc = !pinChatSequenceDesc
            }) {
                Image(systemName: pinChatSequenceDesc ? "pin" : "pin.slash")
                    .font(.system(size: 24))
                    .padding(12)
                    .contentShape(Rectangle())
                    .foregroundStyle(pinChatSequenceDesc ? Color(.controlTextColor) : Color(.disabledControlTextColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 12)
        .padding([.leading, .trailing], 24)
    }
}

struct ChatNameInput: View {
    @Binding var textInEdit: String
    @State private var isHovered: Bool = false

    init(_ textInEdit: Binding<String>) {
        _textInEdit = textInEdit
    }

    var body: some View {
        TextField("Name (optional)", text: $textInEdit, axis: .vertical)
            .font(.system(size: 36))
            .foregroundColor(.gray)
            .textFieldStyle(.plain)
            .padding([.top, .bottom], 12)
        // Draws a single baseline bar at the bottom of the control
            .overlay(
                Divider().background(Color.accentColor), alignment: .bottom
            )
            .lineLimit(1...10)
            .scrollDisabled(false)
            .background(isHovered ? Color(.selectedControlColor) : Color.clear)
        // Add the tiniest of padding, so the background doesn't go out of the safe area.
            .padding(.top, 1)
            .padding([.leading, .trailing], 24)
            .frame(maxWidth: .infinity)
            .onHover { isHovered in
                self.isHovered = isHovered
            }
    }
}

struct InlineTextInput: View {
    @Binding var textInEdit: String
    @Binding var allowNewlineSubmit: Bool

    @State var isHovered: Bool = false
    var isFocused: FocusState<Bool>.Binding

    var submitFunc: (() -> Void)

    init(
        _ textInEdit: Binding<String>,
        allowNewlineSubmit: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding,
        submitFunc: (@escaping () -> Void)
    ) {
        _textInEdit = textInEdit
        _allowNewlineSubmit = allowNewlineSubmit
        self.isFocused = isFocused
        self.submitFunc = submitFunc
    }

    var body: some View {
        TextEditor(text: $textInEdit)
            .font(.system(size: 18))
            .lineSpacing(6)
            .monospaced()
            .padding(12)
            .scrollContentBackground(.hidden)
            .background(
                Rectangle()
                    .fill(Color.clear)
                    .strokeBorder(lineWidth: 4)
                    .foregroundColor(Color(.selectedControlColor))
                    .opacity(isHovered ? 1.0 : 0.0)
                )
            .onChange(of: textInEdit) {
                if allowNewlineSubmit {
                    // TODO: This is wonky as all hell, it submits when you paste text that ends with a newline
                    if textInEdit.last?.isNewline == .some(true) {
                        textInEdit.removeLast()
                        self.submitFunc()
                    }
                }
            }
            .onHover { isHovered in
                self.isHovered = isHovered
            }
            .focused(isFocused.projectedValue)
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct ViewHolder: View {
        @State var textInEdit = "typed text"
        @State var allowNewlineSubmit = false
        @FocusState var isFocused: Bool

        var body: some View {
            GeometryReader{geometry in
                VSplitView {
                    Text("upper view")
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity)

                    InlineTextInput($textInEdit, allowNewlineSubmit: $allowNewlineSubmit, isFocused: $isFocused) {}
                        .frame(minHeight: 200)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    return ViewHolder()
}
