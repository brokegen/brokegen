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

    // TODO: These need to be a @Binding, or hosted in the parent/ViewModel, if we want them to persist across settings changes.
    @State private var localExpandContent: Bool? = nil
    private let defaultExpandContent: Bool
    // TODO: These need to be a @Binding, or hosted in the parent/ViewModel, if we want them to persist across settings changes.
    @State private var localRenderAsMarkdown: Bool? = nil
    private let defaultRenderAsMarkdown: Bool

    @State private var isHovered: Bool = false

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

        self.defaultExpandContent = defaultExpandContent
        self.defaultRenderAsMarkdown = defaultRenderAsMarkdown
    }

    var expandContent: Bool {
        get { localExpandContent ?? defaultExpandContent }
    }

    var renderAsMarkdown: Bool {
        get { localRenderAsMarkdown ?? defaultRenderAsMarkdown }
    }

    @ViewBuilder
    func buttons(_ baseFontSize: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: baseFontSize * 2) {
            Button(action: {
                localRenderAsMarkdown = !renderAsMarkdown
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

            if case .stored(_) = self.message {
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
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.borderless)
            .layoutPriority(0.2)

            if stillExpectingUpdate && (!message.content.isEmpty || !expandContent) {
                ProgressView()
                    .controlSize(.mini)
                    .id("progress view")
                    .layoutPriority(0.2)
            }

            Spacer()
        }
        .font(.system(size: baseFontSize * 1.5))
        .padding(baseFontSize * 4/3)
    }

    @ViewBuilder
    var bodyNoButtons: some View {
        let fixedHeaderSize: CGFloat = 12

        if showMessageHeaders {
            headerSection(fixedHeaderSize)
        }

        if expandContent {
            HStack(spacing: 0) {
                if stillExpectingUpdate && message.content.isEmpty {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .padding(messageFontSize * 4/3)
                        .padding(.bottom, messageFontSize * 2/3)
                        .id("progress view")
                        .layoutPriority(0.2)
                }

                else if !message.content.isEmpty {
                    if renderAsMarkdown {
                        MarkdownView(content: renderMessageContent(message), messageFontSize: messageFontSize)
                        // https://stackoverflow.com/questions/56505929/the-text-doesnt-get-wrapped-in-swift-ui
                        // Render faster
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(0.2)
                    }
                    else {
                        Text(message.content)
                            .font(.system(size: messageFontSize * 1.5))
                            .lineSpacing(6)
                            .textSelection(.enabled)
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
    }

    var body: some View {
        let fixedOverlaySize: CGFloat = 12

        VStack(spacing: 0) {
            bodyNoButtons
        }
        .overlay(alignment: .topTrailing) {
            if isHovered && showMessageHeaders {
                HStack(alignment: .bottom, spacing: fixedOverlaySize * 2) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(message.createdAtString)
                        Text(message.sequenceIdString ?? message.messageIdString)
                    }
                    .foregroundStyle(Color(.disabledControlTextColor))

                    buttons(fixedOverlaySize)
                }
                .padding(fixedOverlaySize * 4/3)
                .padding(.trailing, fixedOverlaySize * 1.5)
            }
            else if isHovered && !showMessageHeaders {
                buttons(fixedOverlaySize)
                    .padding(fixedOverlaySize * 4/3)
                    .background(
                        Rectangle()
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
