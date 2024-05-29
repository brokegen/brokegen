import Combine
import SwiftUI

struct InlineTextInput: View {
    @Binding var textInEdit: String
    @State var isHovered: Bool = false
    /// Crossover length where we swap implementations to a TextEditor
    let textFieldMaxChars: Int

    init(
        _ textInEdit: Binding<String>,
        textFieldMaxChars: Int = 280
    ) {
        _textInEdit = textInEdit
        self.textFieldMaxChars = textFieldMaxChars
    }

    var body: some View {
        if textInEdit.count <= textFieldMaxChars {
            TextField("Enter your message", text: $textInEdit, axis: .vertical)
                .textFieldStyle(.plain)
                .lineSpacing(240)
                .monospaced()
                .lineLimit(4...40)
                .background(
                    isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
                )
                .onHover { isHovered in
                    self.isHovered = isHovered
                }
                .padding(6)
        }
        else {
            TextEditor(text: $textInEdit)
                .scrollDisabled(true)
                .monospaced()
                .lineLimit(4...40)
                .background(
                    isHovered ? Color(.controlColor) : Color(.controlBackgroundColor)
                )
                .onHover { isHovered in
                    self.isHovered = isHovered
                }
                .padding(6)
        }
    }
}

struct OneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    let sequence: ChatSequence

    @State var promptInEdit: String = ""
    /// When done submitting, migrate promptInEdit into a new Message
    @State var submitting: Bool = false

    @State var responseInEdit: Message? = nil
    /// When done receiving, migrate responseInEdit into a new Message
    @State var receiving: Bool = false
    @State var receivingStreamer: AnyCancellable? = nil

    init(_ sequence: ChatSequence) {
        self.sequence = sequence
    }

    func submitWithoutPrompt(
        model continuationModelId: InferenceModelRecordID? = nil
    ) -> OneSequenceView {
        Task.init {
            guard submitting == false else {
                print("[ERROR] OneSequenceView.submitWithoutPrompt during another submission")
                return
            }
            submitting = true

            receivingStreamer = await chatService.sequenceContinue(sequence.serverId!, model: continuationModelId)
                .sink(receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        if responseInEdit == nil {
                            print("[ERROR] ChatSyncService.sequenceContinue completed without any response data")
                        }
                        else {
                            sequence.messages.append(responseInEdit!)
                            responseInEdit = nil
                        }
                        stopSubmitAndReceive()
                    case .failure(let error):
                        let errorMessage = Message(
                            role: "[ERROR] ChatSyncService.sequenceContinue: \(error.localizedDescription)",
                            content: responseInEdit?.content ?? "",
                            createdAt: Date.now
                        )
                        sequence.messages.append(errorMessage)
                        responseInEdit = nil

                        stopSubmitAndReceive()
                    }
                }, receiveValue: { data in
                    // On first data received, end "submitting" phase
                    submitting = false
                    receiving = true

                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                        if let message = jsonDict["message"] as? [String : Any] {
                            if let fragment = message["content"] {
                                let newResponse = Message(
                                    role: responseInEdit!.role,
                                    content: responseInEdit!.content + (fragment as! String),
                                    createdAt: responseInEdit!.createdAt
                                )
                                responseInEdit = newResponse
                            }
                        }

                        if let done = jsonDict["done"] as? Bool {
                            let newSequenceId: Int? = jsonDict["new_sequence_id"] as? Int
                            if done && newSequenceId != nil {
                                print("[DEBUG] Should update to new_sequence_id: \(newSequenceId!)")
                                chatService.replaceSequence(sequence.serverId!, with: newSequenceId!)
                            }
                        }
                    }
                    catch {
                        print("[ERROR] OneSequenceView.submitWithoutPrompt: decoding error or something")
                    }
                })
        }

        return self
    }

    func submit() {
        Task.init {
            /// TODO: Avoid race conditions by migrating to actor
            guard submitting == false else {
                print("[ERROR] OneSequenceView.submit during another submission")
                return
            }
            submitting = true

            let nextMessage = Message(
                role: "user",
                content: promptInEdit,
                createdAt: Date.now
            )

            receivingStreamer = await chatService.sequenceExtend(nextMessage, id: sequence.serverId!)
                .sink(receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        if responseInEdit == nil {
                            print("[ERROR] ChatSyncService.sequenceExtend completed without any response data")
                        }
                        else {
                            sequence.messages.append(responseInEdit!)
                            responseInEdit = nil
                        }
                        stopSubmitAndReceive()
                    case .failure(let error):
                        let errorMessage = Message(
                            role: "[ERROR] ChatSyncService.sequenceExtend: \(error.localizedDescription)",
                            content: responseInEdit?.content ?? "",
                            createdAt: Date.now
                        )
                        sequence.messages.append(errorMessage)
                        responseInEdit = nil

                        stopSubmitAndReceive()
                    }
                }, receiveValue: { data in
                    // On first data received, end "submitting" phase
                    if submitting {
                        sequence.messages.append(nextMessage)

                        promptInEdit = ""
                        submitting = false

                        responseInEdit = Message(
                            role: "assistant",
                            content: "",
                            createdAt: Date.now
                        )
                    }
                    receiving = true

                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data) as! [String : Any]
                        if let message = jsonDict["message"] as? [String : Any] {
                            if let fragment = message["content"] {
                                let newResponse = Message(
                                    role: responseInEdit!.role,
                                    content: responseInEdit!.content + (fragment as! String),
                                    createdAt: responseInEdit!.createdAt
                                )
                                responseInEdit = newResponse
                            }
                        }

                        if let done = jsonDict["done"] as? Bool {
                            let newSequenceId: Int? = jsonDict["new_sequence_id"] as? Int
                            if done && newSequenceId != nil {
                                print("[DEBUG] Should update to new_sequence_id: \(newSequenceId!)")
                                chatService.replaceSequence(sequence.serverId!, with: newSequenceId!)
                            }
                        }
                    }
                    catch {
                        print("[ERROR] OneSequenceView.submit: decoding error or something")
                    }
                })
        }
    }

    func stopSubmitAndReceive() {
        receivingStreamer?.cancel()
        receivingStreamer = nil

        submitting = false
        receiving = false
    }

    var body: some View {
        List {
            ForEach(sequence.messages) { message in
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
                        submit()
                    }

                VStack {
                    Button(action: stopSubmitAndReceive) {
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

                    Button(action: submit) {
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
        let sequence = try ChatSequence(-1, data: try encoder.encode(parameters))
        return OneSequenceView(sequence)
            .environment(ChatSyncService())
    }
    catch {
        return Text("Failed to construct OneSequenceView")
    }
}
