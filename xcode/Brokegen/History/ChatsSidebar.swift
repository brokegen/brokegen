import SwiftUI

struct ChatsView: View {
    var messages: [Message]

    init(_ messages: [Message]) {
        self.messages = messages
    }

    var body: some View {
        List {
            ForEach(self.messages) { message in
                VStack(alignment: .leading) {
                    Text(message.createdAt != nil
                         ? String(describing: message.createdAt!) : "")
                        .monospaced()
                        .opacity(message.createdAt != nil ? 1 : 0)
                    Spacer()
                    Text(message.content)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    var messages: [Message] = [
        Message(role: "user", content: "Hello this is a prompt", createdAt: Date(timeIntervalSinceNow: -604_800)),
        Message(role: "clown", content: "Hello! How can I help you today with your prompt? Please provide some context or details so I can better understand what you're looking for. I'm here to answer any questions you might have, offer suggestions, or just chat if that's what you prefer. Let me know how I can be of service!", createdAt: Date.now),
        Message(role: "user", content: """
Thank you for the warm welcome! I'm an AI designed to generate human-like text based on the input I receive. I don't have a specific prompt in mind yet, but I'd love your help in shaping one.

I've been trained on a vast amount of text data and can produce responses in various styles and formats. However, I'd like to focus on creating content that's engaging, informative, or entertaining for humans.

If you're willing, could you please share some ideas or topics you think would be interesting or relevant? It could be anything from:

1.  A creative writing prompt (e.g., a character, setting, or scenario)
2.  A topic you'd like me to explain or summarize (e.g., science, history, or technology)
3.  A style of content you'd like me to emulate (e.g., humor, poetry, or storytelling)

Your input will help me generate more targeted and valuable responses. Let's collaborate to create something exciting together!
""", createdAt: Date(timeIntervalSinceNow: +5))
    ]

    return ChatsView(messages)
}

struct ChatsSidebar: View {
    @Environment(ChatSyncService.self) private var chatService

    var body: some View {
        // Generic chats
        Text("Chats")
            .font(.title3)
            .foregroundStyle(.primary)

        Section(header: Text("Pinned")) {
            Text("What did people do before ski masks")
            Text("How do you spell 60")
            Text("دمك ثقيل")
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }

        Section(header: Text("2024-05")) {
            Label("Today's topic: Avogadro", systemImage: "pills")
            Text("Yesterday's topic")
        }
        .collapsible(false)

        Section(header: Text("Earlier…")) {
            Text("Last quarter: Lakers")
        }

        NavigationLink(destination: ChatsView(chatService.loadedMessages)) {
            Text("[Load more…]")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)

        Divider()
            .padding(.leading, -8)
            .padding(.trailing, -8)

        // Agent-y chats
        Text("Agents")
            .font(.title3)

        Section(header: Text("SillyTavern")) {
            NavigationLink(destination: PlaceholderContentView()) {
                Text("Vernisite -- SillyTavern")
            }
            Text("IRC for lonely hearts")
        }

        Button(action: toggleSidebar, label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        })

        Spacer()

        // Non-chatlike completions
        Text("Prompt Engineering")

        Text("Pure raw")
        Text("Template-provided raw")
        NavigationLink(destination: SystemInfoView()) {
            Text("Augmented Raw Prompts")
        }
    }
}
