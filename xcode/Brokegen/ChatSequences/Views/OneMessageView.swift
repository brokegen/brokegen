import MarkdownUI
import SwiftUI

struct OneMessageView: View {
    let message: MessageLike
    let renderMessageContent: (MessageLike) -> MarkdownContent
    let sequence: ChatSequence?
    let branchAction: (() -> Void)?
    let stillExpectingUpdate: Bool
    let showMessageHeaders: Bool
    let messageFontSize: CGFloat

    @State private var expandContent: Bool
    @State private var isHovered: Bool = false
    @State private var renderMessageAsMarkdown: Bool?
    @Binding private var defaultRenderAsMarkdown: Bool

    init(
        _ message: MessageLike,
        renderMessageContent: @escaping ((MessageLike) -> MarkdownContent) = {
            MarkdownContent($0.content)
        },
        sequence: ChatSequence? = nil,
        branchAction: (() -> Void)? = nil,
        stillUpdating stillExpectingUpdate: Bool = false,
        showMessageHeaders: Bool,
        messageFontSize: CGFloat = 12,
        renderAsMarkdown defaultRenderAsMarkdown: Binding<Bool>
    ) {
        self.message = message
        self.renderMessageContent = renderMessageContent
        self.sequence = sequence
        self.branchAction = branchAction
        self.stillExpectingUpdate = stillExpectingUpdate
        self.messageFontSize = messageFontSize
        self.showMessageHeaders = showMessageHeaders

        self._renderMessageAsMarkdown = State(initialValue: nil)
        self._defaultRenderAsMarkdown = defaultRenderAsMarkdown

        self._expandContent = State(
            initialValue: message.role == "user" || message.role == "assistant"
        )
    }

    var renderAsMarkdown: Bool {
        get { return renderMessageAsMarkdown ?? defaultRenderAsMarkdown }
    }

    var buttons: some View {
        HStack(spacing: messageFontSize * 2) {
            Button(action: {
                renderMessageAsMarkdown = !renderAsMarkdown
            }, label: {
                Image(systemName: renderAsMarkdown ? "doc.richtext.fill" : "doc.richtext")
            })

            Button(action: {
                let pasteboard = NSPasteboard.general
                // https://stackoverflow.com/questions/49211910/s
                pasteboard.clearContents()
                pasteboard.setString(message.content, forType: .string)
            }, label: {
                Image(systemName: "clipboard")
            })

            if case .stored(let message) = self.message {
                Button(action: { self.branchAction?() }, label: {
                    Image(systemName: "arrow.triangle.branch")
                })
                .disabled(self.branchAction == nil)
            }
            else {
                Button(action: {}, label: {
                    Image(systemName: "arrow.triangle.branch")
                })
                .disabled(true)
            }
        }
        .font(.system(size: messageFontSize * 2))
        .buttonStyle(.borderless)
    }

    var headerSection: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Button(action: {
                withAnimation(.snappy) {
                    expandContent.toggle()
                }
            }, label: {
                HStack(alignment: .bottom, spacing: 0) {
                    Image(systemName: expandContent ? "chevron.down" : "chevron.right")
                        .contentTransition(.symbolEffect)
                        .font(.system(size: messageFontSize * 1.5))
                        .frame(width: 2 + messageFontSize * 1.5, height: messageFontSize * 1.5)
                        .modifier(ForegroundAccentColor(enabled: !expandContent))
                        .padding(.trailing, messageFontSize)

                    Text(message.role)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(.trailing, messageFontSize)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.borderless)

            if stillExpectingUpdate && (!message.content.isEmpty || !expandContent) {
                ProgressView()
                    .controlSize(.mini)
                    .id("progress view")
            }

            Spacer()

            if isHovered {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(message.createdAtString)
                    Text(message.sequenceIdString ?? message.messageIdString)
                }
                .foregroundStyle(Color(.disabledControlTextColor))
                .padding(.leading, messageFontSize * 2)
                .padding(.trailing, messageFontSize * 2)

                buttons
                    .padding(.trailing, 18)
            }
        }
        .font(.system(size: messageFontSize * 1.5))
        .padding(16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showMessageHeaders {
                headerSection
            }

            if stillExpectingUpdate && (message.content.isEmpty && expandContent) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .padding(messageFontSize * 1.5)
                    .padding(.bottom, messageFontSize * 0.5)
                    .id("progress view")
            }

            if expandContent && !message.content.isEmpty {
                ZStack(alignment: .topTrailing) {
                    if renderAsMarkdown {
                        MarkdownView(content: renderMessageContent(message), messageFontSize: messageFontSize)
                        // https://stackoverflow.com/questions/56505929/the-text-doesnt-get-wrapped-in-swift-ui
                        // Render faster
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    else {
                        Text(message.content)
                            .font(.system(size: messageFontSize * 1.5))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .padding(messageFontSize * 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: messageFontSize, style: .continuous)
                                    .fill(Color(.controlBackgroundColor))
                            )
                        // https://stackoverflow.com/questions/56505929/the-text-doesnt-get-wrapped-in-swift-ui
                        // Render faster
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !showMessageHeaders && isHovered {
                        buttons
                            .padding(messageFontSize * 1.5)
                            .background(
                                Rectangle()
                                    .fill(Color(.controlBackgroundColor))
                                    .opacity(0.8)
                            )
                            .padding(.trailing, messageFontSize * 1.5)
                    }
                }
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
        ```
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

        ---
        ok
        """, createdAt: Date(timeIntervalSinceNow: +200))

    let showMessageHeaders = true

    return VStack(alignment: .leading, spacing: 0) {
        OneMessageView(
            .temporary(TemporaryChatMessage(
                role: "user",
                content: "Hello this is a prompt",
                createdAt: Date(timeIntervalSinceNow: -604_800))),
            showMessageHeaders: showMessageHeaders, renderAsMarkdown: .constant(false))

        OneMessageView(
            .temporary(TemporaryChatMessage(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now)),
            showMessageHeaders: showMessageHeaders, renderAsMarkdown: .constant(false))

        OneMessageView(.temporary(message3), showMessageHeaders: showMessageHeaders, messageFontSize: 24, renderAsMarkdown: .constant(true))

        OneMessageView(.temporary(message4), showMessageHeaders: showMessageHeaders, renderAsMarkdown: .constant(false))

        Spacer()
    }
}
