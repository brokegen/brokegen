import SwiftUI

struct PrettyDate: View {
    let date: Date?
    let dateStr: String

    init(_ date: Date?) {
        self.date = date
        if self.date != nil {
            self.dateStr = String(describing: date!)
        }
        else {
            self.dateStr = ""
        }
    }

    var body: some View {
        Text(self.dateStr)
            .monospaced()
    }
}

struct OneMessageView: View {
    let message: Message
    let sequence: ChatSequence?
    @State var expandDetails: Bool

    init(_ message: Message, sequence: ChatSequence? = nil) {
        self.message = message
        self.sequence = sequence
        self._expandDetails = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // "Header" for the message
            HStack(alignment: .center, spacing: 8) {
                Text(message.role)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.accentColor)

                Spacer()

                Button(action: { expandDetails = !expandDetails }) {
                    Image(systemName: expandDetails ? "chevron.down" : "chevron.left")
                }
                    .buttonStyle(.accessoryBar)
                    .help("Expand Details")
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 32)
            }

            // Second line-block
            if expandDetails {
                HStack {
                    Spacer()
                    PrettyDate(message.createdAt)
                }
            }

            Text(message.content)
                .lineSpacing(6)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    public func expandDetails(_ expandDetails: Bool) -> OneMessageView {
        var view = self
        view.expandDetails = expandDetails

        return view
    }
}


#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    VStack {
        OneMessageView(
            Message(role: "user", content: "Hello this is a prompt", createdAt: Date(timeIntervalSinceNow: -604_800)))
            .expandDetails(false)

        OneMessageView(
            Message(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now))
            .expandDetails(true)

        OneMessageView(
            Message(role: "user", content: """
Thank you for the warm welcome! I'm an AI designed to generate human-like text based on the input I receive. I don't have a specific prompt in mind yet, but I'd love your help in shaping one.

I've been trained on a vast amount of text data and can produce responses in various styles and formats. However, I'd like to focus on creating content that's engaging, informative, or entertaining for humans.

If you're willing, could you please share some ideas or topics you think would be interesting or relevant? It could be anything from:

1.  A creative writing prompt (e.g., a character, setting, or scenario)
2.  A topic you'd like me to explain or summarize (e.g., science, history, or technology)
3.  A style of content you'd like me to emulate (e.g., humor, poetry, or storytelling)

Your input will help me generate more targeted and valuable responses. Let's collaborate to create something exciting together!
""", createdAt: Date(timeIntervalSinceNow: +5)))

        Spacer()
    }
}
