import Combine
import SwiftUI

let inputBackgroundStyle = Color(.controlBackgroundColor)

struct OneSequenceView: View {
    @ObservedObject var viewModel: ChatSequenceClientModel

    @FocusState var focusTextInput: Bool

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                if viewModel.sequence.humanDesc != nil {
                    HStack {
                        Text(viewModel.sequence.humanDesc!)
                            .font(.system(size: 36))
                            .padding(.leading, 24)
                            .foregroundColor(.gray)
                            .lineLimit(1)

                        Spacer()
                    }
                }

                ForEach(viewModel.sequence.messages) { message in
                    OneMessageView(message)
                        .padding(24)
                        .padding(.top, 16)
                }

                if viewModel.responseInEdit != nil {
                    OneMessageView(viewModel.responseInEdit!)
                        .padding(24)
                        .padding(.top, 16)
                }

                if viewModel.submitting || viewModel.responseInEdit != nil || viewModel.displayedStatus != nil {
                    // TODO: This doesn't seem like the right UI move, but I don't understand colors yet
                    Divider()

                    HStack {
                        if viewModel.displayedStatus != nil {
                            // TODO: Find a way to persist any changes for at least a few seconds
                            Text(viewModel.displayedStatus ?? "")
                                .foregroundStyle(Color(.disabledControlTextColor))
                        }

                        Spacer()

                        if viewModel.submitting || viewModel.responseInEdit != nil {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 120)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                }

                HStack {
                    let disableControls: Bool = viewModel.submitting || viewModel.responseInEdit != nil

                    InlineTextInput($viewModel.promptInEdit, isFocused: $focusTextInput)
                        .setDisabled(disableControls)
                        .focused($focusTextInput)
                        .disabled(disableControls)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                self.focusTextInput = true
                            }
                        }
                        .backgroundStyle(inputBackgroundStyle)

                    Group {
                        Button(action: {
                            viewModel.stopSubmitAndReceive(userRequested: true)
                        }) {
                            Image(systemName: viewModel.responseInEdit != nil ? "stop.fill" : "stop")
                                .font(.system(size: 32))
                                .disabled(!disableControls)
                                .foregroundStyle(!disableControls ? Color(.disabledControlTextColor) : Color(.controlTextColor))
                        }
                        .buttonStyle(.plain)
                        .help("Stop submitting or receiving")
                        .padding(.leading, 12)

                        Button(action: viewModel.requestExtendWithRetrieval) {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 32))
                                .disabled(disableControls)
                                .foregroundStyle(disableControls ? Color(.disabledControlTextColor) : Color(.controlTextColor))
                        }
                        .buttonStyle(.plain)
                        .help("Submit with Retrieval-Augmented Generation")

                        Button(action: {
                            if viewModel.promptInEdit.isEmpty {
                                _ = viewModel.requestContinue()
                            }
                            else {
                                viewModel.requestExtend()
                            }
                        }) {
                            Image(systemName: viewModel.submitting ? "arrow.up.circle.fill" : "arrow.up.circle")
                                .font(.system(size: 32))
                                .disabled(disableControls)
                                .foregroundStyle(disableControls ? Color(.disabledControlTextColor) : Color(.controlTextColor))
                        }
                        .buttonStyle(.plain)
                        .help("Submit")
                    }
                    .padding(.trailing, 12)
                }
                .background(inputBackgroundStyle)
                .frame(maxHeight: 400)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
            }
            .onChange(of: viewModel.sequence.messages) { old, new in
                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
            }
            .onChange(of: viewModel.responseInEdit?.content) {
                // TODO: Replace this with a GeometryReader that merely nudges us, if we're already close to the bottom
                proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
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
        return OneSequenceView(viewModel)
    }
    catch {
        return Text("Failed to construct OneSequenceView")
    }
}
