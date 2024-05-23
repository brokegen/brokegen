import SwiftUI

struct OneMessageView: View {
    var message: Message

    init(_ message: Message) {
        self.message = message
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(message.createdAt != nil
                 ? String(describing: message.createdAt!) : "")
                .monospaced()
                .opacity(message.createdAt != nil ? 1 : 0)
            Text(message.content)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
    }
}


#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    VStack {
        OneMessageView(
            Message(role: "user", content: "Hello this is a prompt", createdAt: Date(timeIntervalSinceNow: -604_800)))

        OneMessageView(
            Message(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now))

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
