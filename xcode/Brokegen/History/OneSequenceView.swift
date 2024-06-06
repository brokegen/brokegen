import Combine
import SwiftUI

let inputBackgroundStyle = Color(.controlBackgroundColor)

struct OneSequenceView: View {
    @ObservedObject var viewModel: ChatSequenceClientModel

    @FocusState var focusTextInput: Bool
    @State var allowNewlineSubmit: Bool = false

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if viewModel.pinSequenceTitle {
                    HStack(spacing: 0) {
                        Text(viewModel.displayHumanDesc)
                            .font(.system(size: 36))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .layoutPriority(0.2)

                        Spacer()

                        Button(action: {
                            viewModel.pinSequenceTitle = false
                        }) {
                            Image(systemName: "pin")
                                .font(.system(size: 24))
                                .padding(12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .id("sequence title")
                    .padding(.bottom, 12)
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                }

                ScrollView(.vertical) {
                    if !viewModel.pinSequenceTitle {
                        HStack(spacing: 0) {
                            Text(viewModel.displayHumanDesc)
                                .font(.system(size: 36))
                                .foregroundColor(.gray)
                                .lineLimit(1...10)
                                .layoutPriority(0.2)

                            Spacer()

                            Button(action: {
                                viewModel.pinSequenceTitle = true
                            }) {
                                Image(systemName: "pin.slash")
                                    .font(.system(size: 24))
                                    .padding(12)
                                    .contentShape(Rectangle())
                                    .foregroundStyle(Color(.disabledControlTextColor))
                            }
                            .buttonStyle(.plain)
                        }
                        .id("sequence title")
                        .padding(.bottom, 12)
                        .padding(.leading, 24)
                        .padding(.trailing, 24)
                    }

                    ForEach(viewModel.sequence.messages) { message in
                        OneMessageView(message)
                            .padding(24)
                            .padding(.top, 16)
                    }

                    if viewModel.responseInEdit != nil {
                        OneMessageView(viewModel.responseInEdit!, stillUpdating: true)
                            .padding(24)
                            .padding(.top, 16)
                    }
                }

                VStack(spacing: 0) {
                    if viewModel.submitting || viewModel.responseInEdit != nil || viewModel.displayedStatus != nil {
                        Divider()

                        HStack {
                            if viewModel.displayedStatus != nil {
                                Text(viewModel.displayedStatus ?? "")
                                    .foregroundStyle(Color(.disabledControlTextColor))
                                    .layoutPriority(0.2)
                            }

                            Spacer()

                            if viewModel.submitting || viewModel.responseInEdit != nil {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 120)
                                    .layoutPriority(0.2)
                            }
                        }
                        .padding(.leading, 24)
                        .padding(.trailing, 24)
                    }

                    HStack {
                        let disableControls: Bool = viewModel.submitting || viewModel.responseInEdit != nil

                        InlineTextInput($viewModel.promptInEdit, allowNewlineSubmit: $allowNewlineSubmit, isFocused: $focusTextInput) {
                            if viewModel.promptInEdit.isEmpty {
                                _ = viewModel.requestContinue()
                            }
                            else {
                                viewModel.requestExtend()
                            }
                        }
                        .focused($focusTextInput)
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
                                    .disabled(disableControls || viewModel.promptInEdit.isEmpty)
                                    .foregroundStyle(
                                        (disableControls || viewModel.promptInEdit.isEmpty)
                                        ? Color(.disabledControlTextColor)
                                        : Color(.controlTextColor))
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
                        } // end of button group
                        .padding(.trailing, 12)
                    }
                } // end of entire lower VStack
                .background(inputBackgroundStyle)
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
        let viewModel = ChatSequenceClientModel(sequence, chatService: chatService, inferenceModelSettings: InferenceModelSettings())
        return OneSequenceView(viewModel)
    }
    catch {
        return Text("Failed to construct OneSequenceView")
    }
}
