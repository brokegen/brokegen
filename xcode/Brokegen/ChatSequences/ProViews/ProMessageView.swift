import SwiftUI

struct ProMessageView: View {
    let message: MessageLike
    let sequence: ChatSequence?
    let stillExpectingUpdate: Bool
    let showMessageHeaders: Bool

    @State var expandContent: Bool
    @State var isHovered: Bool = false

    init(
        _ message: MessageLike,
        sequence: ChatSequence? = nil,
        stillUpdating stillExpectingUpdate: Bool = false,
        showMessageHeaders: Bool
    ) {
        self.message = message
        self.sequence = sequence
        self.stillExpectingUpdate = stillExpectingUpdate
        self.showMessageHeaders = showMessageHeaders

        self._expandContent = State(initialValue: message.role != "model config")
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
                        .font(.system(size: 18))
                        .frame(width: 20, height: 18)
                        .modifier(ForegroundAccentColor(enabled: !expandContent))
                        .padding(.trailing, 12)

                    Text(message.role)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.controlTextColor))
                        .padding(.trailing, 12)
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

            VStack(alignment: .trailing, spacing: 0) {
                Text(message.createdAtString)
                Text(message.serverIdStr)
            }
            .foregroundStyle(Color(.disabledControlTextColor))
            .opacity(isHovered ? 1.0 : 0.0)
            .padding(.leading, 24)
            .padding(.trailing, 24)

            HStack(spacing: 24) {
                Button(action: {}, label: {
                    Image(systemName: "clipboard")
                })

                Button(action: {
                }, label: {
                    Image(systemName: "arrow.triangle.branch")
                })

                Button(action: {}, label: {
                    Image(systemName: "info.circle")
                })
            }
            .font(.system(size: 24))
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1.0 : 0.0)
            .disabled(!isHovered)
            .padding(.trailing, 18)
        }
        .font(.system(size: 18))
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
                    .padding(16)
                    .padding(.bottom, 8)
                    .id("progress view")
            }

            if expandContent && !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 18))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.controlBackgroundColor))
                    )
            }
        }
        // TODO: Checking this gets really slow
        .onHover { isHovered in
            // TODO: Animating this gets really slow
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

Your input will help me generate more targeted and valuable responses. Let's collaborate to create something exciting together!
""", createdAt: Date(timeIntervalSinceNow: +5))

    let showMessageHeaders = true

    return VStack(alignment: .leading, spacing: 0) {
        ProMessageView(
            .stored(ChatMessage(serverId: -3, role: "user", content: "Hello this is a prompt", createdAt: Date(timeIntervalSinceNow: -604_800))), showMessageHeaders: showMessageHeaders)

        ProMessageView(
            .temporary(TemporaryChatMessage(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now)), showMessageHeaders: showMessageHeaders)

        ProMessageView(.temporary(message3), showMessageHeaders: showMessageHeaders)

        Spacer()
    }
}
