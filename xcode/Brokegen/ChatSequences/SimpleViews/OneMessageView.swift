import SwiftUI

struct OneMessageView: View {
    let message: Message
    let sequence: ChatSequence?
    let stillExpectingUpdate: Bool

    @State var expandContent: Bool

    init(
        _ message: Message,
        sequence: ChatSequence? = nil,
        stillUpdating: Bool = false
    ) {
        self.message = message
        self.sequence = sequence
        self.stillExpectingUpdate = stillUpdating
        self._expandContent = State(initialValue: message.role != "model config")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "Header" for the message
            HStack(spacing: 0) {
                Button(action: {
                    withAnimation(.snappy) {
                        expandContent = !expandContent
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

                let dateStr = {
                    if message.createdAt != nil {
                        String(describing: message.createdAt!)
                    }
                    else {
                        ""
                    }
                }()

                Text(dateStr)
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .padding(.trailing, 18)
            }
            .frame(height: 42)
            .font(.system(size: 18))
            .padding(.top, 16)
            .padding([.leading, .trailing], 16)

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
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.controlBackgroundColor))
                    )
                    .padding(.bottom, 8)
            }
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    var updatingMessage = Message(role: "assistant 2", content: "", createdAt: Date.distantFuture)
    var nextMessage: Int = 4

    return VStack(spacing: 0) {
        // TODO: This button does not work. Leave it for the refactor.
        Button(action: {
            updatingMessage = updatingMessage.appendContent("\(nextMessage) ")
            nextMessage += 1
        }) {
            Text("add text")
                .padding(24)
        }

        OneMessageView(
            Message(role: "assistant 1", content: "This is a response continuation, 1 2 3-", createdAt: Date.distantFuture),
            stillUpdating: true
        )

        OneMessageView(
            updatingMessage,
            stillUpdating: true
        )

        Spacer()
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    let message3 = Message(role: "user", content: """
Thank you for the warm welcome! I'm an AI designed to generate human-like text based on the input I receive. I don't have a specific prompt in mind yet, but I'd love your help in shaping one.

I've been trained on a vast amount of text data and can produce responses in various styles and formats. However, I'd like to focus on creating content that's engaging, informative, or entertaining for humans.

If you're willing, could you please share some ideas or topics you think would be interesting or relevant? It could be anything from:

1.  A creative writing prompt (e.g., a character, setting, or scenario)
2.  A topic you'd like me to explain or summarize (e.g., science, history, or technology)
3.  A style of content you'd like me to emulate (e.g., humor, poetry, or storytelling)

Your input will help me generate more targeted and valuable responses. Let's collaborate to create something exciting together!
""", createdAt: Date(timeIntervalSinceNow: +5))

    return VStack {
        OneMessageView(
            Message(role: "user", content: "Hello this is a prompt", createdAt: Date(timeIntervalSinceNow: -604_800)))

        OneMessageView(
            Message(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now))

        OneMessageView(message3)

        Spacer()
    }
}
