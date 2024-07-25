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
                .textSelection(.enabled)
            // If the chat is pinned, allow a short, scrollable view at the top.
            // Otherwise, let it run long.
                .lineLimit(pinChatSequenceDesc ? 1...1 : 1...30)
                .scrollDisabled(!pinChatSequenceDesc)
                .layoutPriority(0.2)

            Spacer()

            Button(action: {
                pinChatSequenceDesc.toggle()
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
    let initialName: String
    @Binding var name: String?
    @State private var isHovered: Bool = false

    init(_ name: Binding<String?>, initialName: String = "Chat name (optional)") {
        self.initialName = initialName
        _name = name
    }

    var body: some View {
        TextField(
            initialName,
            text: Binding(
                get: { name ?? "" },
                set: { name = $0 }
            ),
            axis: .vertical
        )
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
        // Add the tiniest of .top padding, so the background doesn't go out of the safe area.
            .safeAreaPadding(.top, 1)
            .padding([.leading, .trailing], 24)
            .frame(maxWidth: .infinity)
            .onHover { isHovered in
                self.isHovered = isHovered
            }
    }
}

struct InlineTextInput: View {
    @Binding var textInEdit: String

    @State var isHovered: Bool = false
    var isFocused: FocusState<Bool>.Binding

    init(
        _ textInEdit: Binding<String>,
        isFocused: FocusState<Bool>.Binding
    ) {
        _textInEdit = textInEdit
        self.isFocused = isFocused
    }

    var body: some View {
        TextEditor(text: $textInEdit)
            .font(.system(size: 18))
            .lineSpacing(6)
            .padding(12)
            .scrollContentBackground(.hidden)
            .background(
                Rectangle()
                    .fill(Color.clear)
                    .strokeBorder(lineWidth: 4)
                    .foregroundColor(Color(.selectedControlColor))
                    .opacity(isHovered ? 1.0 : 0.0)
                )
            .onHover { isHovered in
                self.isHovered = isHovered
            }
            .focused(isFocused.projectedValue)
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct ViewHolder: View {
        @State var textInEdit = "typed text"
        @FocusState var isFocused: Bool

        var body: some View {
            GeometryReader{geometry in
                VSplitView {
                    Text("upper view")
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity)

                    InlineTextInput($textInEdit, isFocused: $isFocused)
                        .frame(minHeight: 200)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    return ViewHolder()
}
