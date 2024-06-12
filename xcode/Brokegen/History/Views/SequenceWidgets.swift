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

struct ChatNameInput: View {
    @Binding var textInEdit: String
    @State private var isHovered: Bool = false

    init(_ textInEdit: Binding<String>) {
        _textInEdit = textInEdit
    }

    var body: some View {
        TextField("(optional) ChatSequence name", text: $textInEdit, axis: .vertical)
            .font(.system(size: 36))
            .foregroundColor(.gray)
            .lineLimit(1...2)
            .textFieldStyle(.plain)
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
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .padding(4)
            .background(isHovered ? Color(.selectedControlColor) : Color(.controlBackgroundColor))
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
