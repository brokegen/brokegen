import MarkdownUI
import SwiftUI


struct OMVButton: View {
    @Environment(\.isEnabled) var isEnabled

    @State var isButtonHovered = false
    @State var isButtonPressed = false

    let imageSystemName: String
    let action: () async -> Void

    init(
        _ imageSystemName: String,
        action: (@escaping () async -> Void) = {}
    ) {
        self.imageSystemName = imageSystemName
        self.action = action
    }

    // TODO: The hovering doesnt' work unless/until the view is scrolled a little.
    // Something else is intercepting the hover/etc events, during the initial static view.
    var body: some View {
        Image(systemName: imageSystemName)
            .contentShape(Rectangle())
            .onHover { isHovered in
                self.isButtonHovered = isHovered
            }
            .onTapGesture {
                self.isButtonPressed = true
                Task {
                    await action()
                    self.isButtonPressed = false
                }
            }
            .onLongPressGesture(perform: {
                Task {
                    await action()
                }
            }, onPressingChanged: { pressing in
                self.isButtonPressed = pressing
            })
            .background(
                Circle()
                    .stroke(Color(.controlTextColor), lineWidth: isButtonHovered ? 2 : 0)
                    .blur(radius: isButtonHovered ? 8 : 0)
                    .animation(.easeOut(duration: 0.1), value: isButtonHovered)
            )
            .foregroundStyle(
                isEnabled
                ? (isButtonHovered ? Color(.controlAccentColor) : Color(.controlTextColor))
                : Color(.disabledControlTextColor))
            .scaleEffect(self.isButtonPressed ? 0.9 : 1.0)
    }
}

struct TextSelection: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .textSelection(.enabled)
        }
        else {
            content
                .textSelection(.disabled)
        }
    }
}

fileprivate func messageTooLong(_ content: String) -> Bool {
    // markdown lib fails on large messages, so never parse them
    return content.count > 10_000
}

fileprivate func hasReasoningTokens(_ content: String) -> Bool {
    return content.contains("</think>")
}

fileprivate func removeReasoningTokens(_ content: String) -> String {
    let splitMessage = content.split(separator: "</think>")
    return String(splitMessage.last ?? "")
        // Remove leading newlines, since those are frequently seen after </think>.
        .replacingOccurrences(of: #"^\s*"#, with: "", options: .regularExpression)
}

struct OneMessageView: View {
    let message: MessageLike
    let renderMessageContent: (String) -> MarkdownContent
    let sequence: ChatSequence?
    let branchAction: (() async -> Void)?
    let stillExpectingUpdate: Bool
    let showMessageHeaders: Bool
    let messageFontSize: CGFloat
    let shouldAnimate: Bool

    // TODO: These need to be a @Binding, or hosted in the parent/ViewModel, if we want them to persist across settings changes.
    @State private var localExpandContent: Bool? = nil
    private let defaultExpandContent: Bool
    // TODO: These need to be a @Binding, or hosted in the parent/ViewModel, if we want them to persist across settings changes.
    @State private var localRenderAsMarkdown: Bool? = nil
    private let defaultRenderAsMarkdown: Bool

    @State private var localHideReasoning: Bool? = nil
    private let defaultHideReasoning: Bool = true

    @State private var isHovered: Bool = false

    init(
        _ message: MessageLike,
        renderMessageContent: @escaping ((String) -> MarkdownContent) = {
            MarkdownContent($0)
        },
        sequence: ChatSequence? = nil,
        branchAction: (() async -> Void)? = nil,
        stillUpdating stillExpectingUpdate: Bool = false,
        showMessageHeaders: Bool,
        messageFontSize: CGFloat = 12,
        shouldAnimate: Bool = false,
        expandContent defaultExpandContent: Bool,
        renderAsMarkdown defaultRenderAsMarkdown: Bool
    ) {
        self.message = message
        self.renderMessageContent = renderMessageContent
        self.sequence = sequence
        self.branchAction = branchAction
        self.stillExpectingUpdate = stillExpectingUpdate
        self.showMessageHeaders = showMessageHeaders
        self.messageFontSize = messageFontSize
        self.shouldAnimate = shouldAnimate

        self.defaultExpandContent = defaultExpandContent
        self.defaultRenderAsMarkdown = defaultRenderAsMarkdown
    }

    var expandContent: Bool {
        get { localExpandContent ?? defaultExpandContent }
    }

    var renderAsMarkdown: Bool {
        get { localRenderAsMarkdown ?? defaultRenderAsMarkdown }
    }

    var hideReasoning: Bool {
        get { localHideReasoning ?? defaultHideReasoning }
    }

    var hideReasoningMessageContent: String {
        get {
            if hideReasoning && hasReasoningTokens(message.content) {
                removeReasoningTokens(message.content)
            }
            else {
                message.content
            }
        }
    }

    @ViewBuilder
    func buttons(_ baseFontSize: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: baseFontSize * 2) {
            OMVButton(hideReasoning ? "lightbulb.slash" : "lightbulb") {
                localHideReasoning = !hideReasoning
            }
            .disabled(!stillExpectingUpdate && !hasReasoningTokens(message.content))

            OMVButton(renderAsMarkdown ? "doc.richtext.fill" : "doc.richtext") {
                localRenderAsMarkdown = !renderAsMarkdown
            }
            .disabled(messageTooLong(message.content))

            OMVButton("clipboard") {
                let pasteboard = NSPasteboard.general
                // https://stackoverflow.com/questions/49211910/s
                pasteboard.clearContents()
                pasteboard.setString(hideReasoningMessageContent, forType: .string)
            }

            if case .serverOnly(_) = self.message {
                OMVButton("arrow.triangle.branch") {
                    await self.branchAction?()
                }
                .disabled(self.branchAction == nil)
            }
            else {
                OMVButton("arrow.triangle.branch")
                    .disabled(true)
            }
        }
        .font(.system(size: baseFontSize * 2))
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    func headerSection(_ baseFontSize: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Button(action: {
                withAnimation(.snappy) {
                    localExpandContent = !expandContent
                }
            }, label: {
                HStack(alignment: .bottom, spacing: 0) {
                    Image(systemName: expandContent ? "chevron.down" : "chevron.right")
                        .contentTransition(.symbolEffect)
                        .font(.system(size: baseFontSize * 1.5))
                        .frame(width: 2 + baseFontSize * 1.5, height: baseFontSize * 1.5)
                        .modifier(ForegroundAccentColor(enabled: !expandContent))
                        .padding(.trailing, baseFontSize)

                    Text(message.role)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(.trailing, baseFontSize)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.borderless)
            .layoutPriority(0.2)

            if stillExpectingUpdate && (!hideReasoningMessageContent.isEmpty || !expandContent) {
                ProgressView()
                    .controlSize(.mini)
                    .id("progress view")
                    .layoutPriority(0.2)
            }

            Spacer()
                .frame(minWidth: 0)
        }
        .font(.system(size: baseFontSize * 1.5))
        .padding(baseFontSize * 4/3)
    }

    @ViewBuilder
    var contentSection: some View {
        HStack(spacing: 0) {
            if stillExpectingUpdate && hideReasoningMessageContent.isEmpty {
                ProgressView()
                    .progressViewStyle(.circular)
                    .padding(messageFontSize * 4/3)
                    .padding(.bottom, messageFontSize * 2/3)
                    .id("progress view")
                    .layoutPriority(0.2)
            }

            else if !hideReasoningMessageContent.isEmpty {
                if renderAsMarkdown && !messageTooLong(hideReasoningMessageContent) {
                    MarkdownView(content: renderMessageContent(hideReasoningMessageContent), messageFontSize: messageFontSize)
                    // https://stackoverflow.com/questions/56505929/the-text-doesnt-get-wrapped-in-swift-ui
                    // Render faster
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(0.2)
                }
                else {
                    Text(hideReasoningMessageContent)
                        .font(.system(size: messageFontSize * 1.5))
                        .lineSpacing(6)
                    // Enabling text selection on very large text views gets difficult;
                    // rely on the extra "copy" button, in those cases.
                        .modifier(TextSelection(enabled: hideReasoningMessageContent.count < 4_000))
                        .padding(messageFontSize * 4/3)
                        .background(
                            RoundedRectangle(cornerRadius: messageFontSize, style: .continuous)
                                .fill(Color(.controlBackgroundColor))
                        )
                    // https://stackoverflow.com/questions/56505929/the-text-doesnt-get-wrapped-in-swift-ui
                    // Render faster
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(0.2)
                }
            }

            Spacer()
                .frame(minWidth: 0)
        }
    }

    var body: some View {
        let fixedOverlaySize: CGFloat = 12
        let fixedHeaderSize: CGFloat = 12

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if showMessageHeaders {
                    headerSection(fixedHeaderSize)
                }

                if expandContent {
                    contentSection
                        .animation(
                            (shouldAnimate && (!renderAsMarkdown || messageTooLong(hideReasoningMessageContent))) ? .easeIn : nil,
                            value: hideReasoningMessageContent
                        )
                }
            }

            Spacer()
        }
        .overlay(alignment: .topTrailing) {
            if isHovered && showMessageHeaders {
                HStack(alignment: .center, spacing: fixedOverlaySize * 2) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(message.createdAtString)
                        Text(message.sequenceIdString ?? message.messageIdString)
                    }
                    .foregroundStyle(Color(.disabledControlTextColor))

                    buttons(fixedOverlaySize)
                        .padding(fixedOverlaySize * 4/3)
                        .background(
                            RoundedRectangle(cornerRadius: fixedOverlaySize)
                                .fill(Color(.controlBackgroundColor))
                                .opacity(0.8)
                        )
                }
                .padding(.trailing, fixedOverlaySize * 1.5)
            }
            else if isHovered && !showMessageHeaders {
                buttons(fixedOverlaySize)
                    .padding(fixedOverlaySize * 4/3)
                    .background(
                        RoundedRectangle(cornerRadius: fixedOverlaySize)
                            .fill(Color(.controlBackgroundColor))
                            .opacity(0.8)
                    )
                    .padding(.trailing, fixedOverlaySize * 1.5)
            }
        }
        .onHover { isHovered in
            withAnimation(.snappy) {
                self.isHovered = isHovered
            }
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    let message3 = TemporaryChatMessage(role: "user", content: """
Thank you for the warm welcome! I'm an AI designed to generate human-like text based on the input I receive. I don't have a specific prompt in mind yet, but I'd love your help in shaping one.

I've been trained on a vast amount of text data and can produce responses in various styles and formats. However, I'd like to focus on creating content that's engaging, informative, or entertaining for humans.

If you're willing, could you please share some ideas or topics you think would be interesting or relevant? It could be anything from:

1.  A creative writing prompt (e.g., a character, setting, or scenario)
2.  A topic you'd like me to explain or summarize (e.g., science, history, or technology)
3.  A style of content you'd like me to emulate (e.g., humor, poetry, or storytelling)
4.  Here's a really long paragraph that extends past the edge of the 800 point preview screen width, because it's crucial to test text and line spacing for a given paragraph.
5.  And an indented blockquote sub-item!
    > We should probably just use a real list of markdown samples from somewhere.

Your input will help me generate more targeted and valuable responses. Let's collaborate to create something exciting together!

> Thanks.
""", createdAt: Date(timeIntervalSinceNow: +5))

    let message4 = TemporaryChatMessage(role: "assistant", content: """
        **This is bold text**
        ```
        **This is bold text**
        ```

        *This text is italicized*
        ```
        *This text is italicized*
        ```

        ~~This was mistaken text~~
        ```
        ~~This was mistaken text~~
        ```


        **This text is _extremely_ important**
        ```
        **This text is _extremely_ important**
        ```


        ***All this text is important***
        ```
        ***All this text is important***
        ```


        MarkdownUI is fully compliant with the [CommonMark Spec](https://spec.commonmark.org/current/).
        ```
        MarkdownUI is fully compliant with the [CommonMark Spec](https://spec.commonmark.org/current/).
        ```


        Visit https://github.com.
        ```
        Visit https://github.com.
        ```

        ---
        Use `git status` to list all new or modified files that haven't yet been committed.

        ```
        Use `git status` to list all new or modified files that haven't yet been committed.
        ```

        ---
        ok
        """, createdAt: Date(timeIntervalSinceNow: +200))

    let showMessageHeaders = true

    return GeometryReader { geometry in
        ScrollView {
            OneMessageView(
                .temporary(TemporaryChatMessage(
                    role: "user",
                    content: "short prompt",
                    createdAt: Date(timeIntervalSinceNow: -604_800)), .user),
                showMessageHeaders: false,
                expandContent: true,
                renderAsMarkdown: false)

            OneMessageView(
                .temporary(TemporaryChatMessage(role: "clown", content: "Hello! How can I help you today with your prompt?\n\nPlease provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now)),
                showMessageHeaders: showMessageHeaders,
                expandContent: false,
                renderAsMarkdown: false)

            OneMessageView(.temporary(message3, .user), showMessageHeaders: showMessageHeaders, messageFontSize: 24, expandContent: true, renderAsMarkdown: true)

            OneMessageView(.temporary(message4, .assistant), showMessageHeaders: showMessageHeaders, expandContent: true, renderAsMarkdown: false)

            Spacer()
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    List {
        OneMessageView(
            .temporary(
                TemporaryChatMessage(
                    role: "really long role message, similar to the network errors that describe a failure: HTTP 429 you need to calm down",
                    content: "",
                    createdAt: Date.now),
                .clientError
            ),
            showMessageHeaders: true,
            expandContent: false,
            renderAsMarkdown: false)

        OneMessageView(
            .temporary(
                TemporaryChatMessage(
                    role: "assistant",
                    content: "message with short header but long body so we align to leading edge and the designer can check whether we did the alignments correctly"
                )),
            showMessageHeaders: true,
            expandContent: true,
            renderAsMarkdown: true)
    }
}
