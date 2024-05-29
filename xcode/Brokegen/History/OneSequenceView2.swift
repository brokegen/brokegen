import Combine
import SwiftUI

struct OneSequenceView2: View {
    let viewModel: ChatSequenceClientModel

    @State var queuedRequests: [(Self) -> ()] = []

    @State var promptInEdit: String = ""
    /// When done submitting, migrate promptInEdit into a new Message
    @State var submitting: Bool = false

    @State var responseInEdit: Message? = nil
    /// When done receiving, migrate responseInEdit into a new Message
    @State var receiving: Bool = false
    @State var receivingStreamer: AnyCancellable? = nil

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        List {
            ForEach(viewModel.sequence.messages) { message in
                OneMessageView(message)
                    .padding(24)
                    .padding(.top, 16)
            }

            if responseInEdit != nil {
                OneMessageView(responseInEdit!)
                    .padding(24)
                    .padding(.top, 16)
            }

            HStack {
                InlineTextInput($promptInEdit)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .border(.blue)
                    .disabled(submitting || receiving)
                    .onSubmit {
                        viewModel.submit()
                    }

                VStack {
                    Button(action: viewModel.stopSubmitAndReceive) {
                        let icon: String = {
                            if submitting || receiving {
                                return "stop.fill"
                            }
                            else {
                                return "stop"
                            }
                        }()
                        Image(systemName: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(!submitting && !receiving)
                    }
                    .buttonStyle(.plain)
                    .help("Stop submitting or receiving")

                    Spacer()

                    Button(action: viewModel.submit) {
                        Image(systemName: submitting ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(submitting || receiving)
                    }
                    .buttonStyle(.plain)
                    .help("Submit")
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
                .padding(.leading, 12)
                .padding(.trailing, -12)
            }
            .padding(.leading, 24)
            .padding(.trailing, 24)
        }
        .onAppear {
            print("[DEBUG] Iterating through \(queuedRequests.count) OneSequenceView.queuedRequests")
            for req in queuedRequests {
                req(self)
            }
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 600)) {
    let messages: [Message] = [
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

    struct Parameters: Codable {
        let humanDesc: String?
        let userPinned: Bool
        var messages: [Message] = []
    }

    let parameters = Parameters(
        humanDesc: "xcode preview",
        userPinned: true,
        messages: messages
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase

    do {
        let chatService = ChatSyncService()
        let sequence = try ChatSequence(-1, data: try encoder.encode(parameters))
        let viewModel = ChatSequenceClientModel(sequence, chatService: chatService)
        return OneSequenceView2(viewModel)
    }
    catch {
        return Text("Failed to construct OneSequenceView")
    }
}
