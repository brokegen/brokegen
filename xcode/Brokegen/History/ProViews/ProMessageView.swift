import SwiftUI

enum MessageLike {
    case legacy(Message)
    case stored(ChatMessage)
    case temporary(TemporaryChatMessage)

    var role: String {
        get {
            switch(self) {
            case .legacy(let m):
                m.role
            case .stored(let m):
                m.role
            case .temporary(let m):
                m.role
            }
        }
    }

    var content: String {
        get {
            switch(self) {
            case .legacy(let m):
                m.content
            case .stored(let m):
                m.content
            case .temporary(let m):
                m.content ?? ""
            }
        }
    }

    var createdAtString: String {
        get {
            switch(self) {
            case .legacy(let m):
                if m.createdAt != nil {
                    String(describing: m.createdAt!)
                }
                else {
                    "[unknown date]"
                }
            case .stored(let m):
                String(describing: m.createdAt)
            case .temporary(let m):
                String(describing: m.createdAt)
            }
        }
    }
}

struct ProMessageView: View {
    let message: MessageLike
    let sequence: ChatSequence?
    let stillExpectingUpdate: Bool

    @State var expandContent: Bool

    init(
        _ message: Message,
        sequence: ChatSequence? = nil,
        stillUpdating: Bool = false
    ) {
        self.init(MessageLike.legacy(message), sequence: sequence, stillUpdating: stillUpdating)
    }

    init(
        _ message: ChatMessage,
        sequence: ChatSequence? = nil,
        stillUpdating: Bool = false
    ) {
        self.init(MessageLike.stored(message), sequence: sequence, stillUpdating: stillUpdating)
    }

    init(
        _ message: TemporaryChatMessage,
        sequence: ChatSequence? = nil,
        stillUpdating: Bool = false
    ) {
        self.init(MessageLike.temporary(message), sequence: sequence, stillUpdating: stillUpdating)
    }

    init(
        _ message: MessageLike,
        sequence: ChatSequence?,
        stillUpdating: Bool
    ) {
        self.message = message
        self.sequence = sequence
        self.stillExpectingUpdate = stillUpdating
        self._expandContent = State(initialValue: message.role != "model config")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // "Header" for the message
            HStack(alignment: .bottom, spacing: 0) {
                Text(message.role)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .layoutPriority(0.5)

                if stillExpectingUpdate {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                }

                Spacer()

                Button(action: {
                    expandContent = !expandContent
                }, label: {
                    HStack(alignment: .bottom, spacing: 0) {
                        Text(message.createdAtString)
                            .padding(.trailing, 18)

                        Image(systemName: expandContent ? "chevron.down" : "chevron.left")
                            .font(.system(size: 18))
                            .frame(width: 20, height: 18)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.borderless)
            }

                Text(expandContent ? message.content : "")
                    .font(.system(size: 18))
                    .lineSpacing(6)
                    .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
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

    return VStack {
        ProMessageView(
            ChatMessage(serverId: -3, role: "user", content: "Hello this is a prompt", createdAt: Date(timeIntervalSinceNow: -604_800)))

        ProMessageView(
            TemporaryChatMessage(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now))

        ProMessageView(message3)

        Spacer()
    }
}