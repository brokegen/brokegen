import SwiftUI

struct BlankOneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    @Environment(PathHost.self) private var pathHost
    @Environment(InferenceModelSettings.self) var settings: InferenceModelSettings

    // variables that should be in a ChatSequenceClientModel
    @State var modelSelection: InferenceModel?
    @State var chatSequenceHumanDesc: String = ""
    @State var submitting: Bool = false
    @State var promptInEdit: String = ""

    @State var showModelPicker: Bool
    @State var allowNewlineSubmit: Bool = false
    @FocusState var focusTextInput: Bool
    @State private var splitViewLoaded: Bool = false

    init(_ initialModel: InferenceModel? = nil) {
        if initialModel == nil {
            _showModelPicker = State(initialValue: true)
        }
        else {
            _showModelPicker = State(initialValue: false)
            self.modelSelection = initialModel
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VSplitView {
                VStack(spacing: 0) {
                    ChatNameInput($chatSequenceHumanDesc)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, 24)
                        .padding(.trailing, 24)

                    // Display the model info, because otherwise there's nothing to see
                    if modelSelection != nil {
                        OneInferenceModelView(model: modelSelection!, modelAvailable: true, modelSelection: $modelSelection, enableModelSelection: false)
                            .frame(maxWidth: 800)
                            .layoutPriority(0.2)
                            .id("selected model")
                    }
                    else if settings.defaultInferenceModel != nil {
                        OneInferenceModelView(model: settings.defaultInferenceModel!, modelAvailable: true, modelSelection: $modelSelection, enableModelSelection: false)
                            .frame(maxWidth: 800)
                            .layoutPriority(0.2)
                            .id("selected model")
                    }
                    else {
                        let finalDesc: String = {
                            if let humanDesc: String = settings.fallbackInferenceModel?.humanId {
                                return "No model selected, will fallback to \(humanDesc)"
                            }
                            else {
                                return "No model selected"
                            }
                        }()
                        Text(finalDesc)
                            .id("selected model")
                            .padding(24)
                            .padding(.top, 120)
                    }

                    Spacer()
                        .frame(minHeight: 0)
                }

                VStack(spacing: 0) {
                    Divider()

                    HStack(spacing: 0) {
                        Text(submitting ? "Submitting ChatMessage + Sequence" : "Ready")
                            .foregroundStyle(Color(.disabledControlTextColor))
                            .layoutPriority(0.2)

                        Spacer()

                        if submitting {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 120)
                                .layoutPriority(0.2)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                    .frame(minHeight: 36)

                    HStack(spacing: 12) {
                        InlineTextInput($promptInEdit, allowNewlineSubmit: $allowNewlineSubmit, isFocused: $focusTextInput) {
                            submit()
                        }
                        .focused($focusTextInput)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    self.focusTextInput = true
                                }
                            }
                            .backgroundStyle(inputBackgroundStyle)

                            Button(action: {
                                if !promptInEdit.isEmpty {
                                    submit(withRetrieval: true)
                                }
                            }) {
                                Image(systemName: "arrow.up.doc")
                                    .font(.system(size: 32))
                                    .disabled(promptInEdit.isEmpty)
                                    .foregroundStyle(promptInEdit.isEmpty
                                                     ? Color(.disabledControlTextColor)
                                                     : Color.accentColor)
                            }
                            .buttonStyle(.plain)

                        Button(action: {
                            if submitting {
                                stopSubmitAndReceive()
                            }
                            else {
                                if !promptInEdit.isEmpty {
                                    submit(withRetrieval: false)
                                }
                                else {
                                    // This is the only disabled case
                                }
                            }
                        }) {
                            Image(systemName: submitting ? "stop.fill" : "arrowshape.up")
                                .font(.system(size: 32))
                                .disabled(!submitting && promptInEdit.isEmpty)
                                .foregroundStyle(
                                    !submitting && promptInEdit.isEmpty
                                    ? Color(.disabledControlTextColor)
                                    : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 12)
                    .background(inputBackgroundStyle)
                    .frame(minHeight: 180, maxHeight: max(
                        180,
                        splitViewLoaded ? geometry.size.height * 0.7 : geometry.size.height * 0.2))
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        splitViewLoaded = true
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .sheet(isPresented: $showModelPicker) {
                ModelPickerView(modelSelection: $modelSelection)
                // Frame is very wide because the way we're positioning incorrectly ignores the sidebar
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height * 0.8,
                        alignment: .top)
                    .animation(.linear(duration: 0.2))
            }
        }
    }

    private func prettyDate(_ requestedDate: Date? = nil) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions.insert(.withFractionalSeconds)

        let date = requestedDate ?? Date.now
        return dateFormatter.string(from: date)
    }

    private func constructUserSequence(id messageID: ChatMessageServerID) async -> ChatSequenceServerID? {
        struct Parameters: Codable {
            var humanDesc: String? = nil
            var userPinned: Bool
            let currentMessage: ChatMessageServerID
            var parentSequence: ChatSequenceServerID? = nil
            var generatedAt: String?
            var generationComplete: Bool
            var inferenceJobId: InferenceEventID? = nil
            var inferenceError: String? = nil
        }
        let params = Parameters(
            humanDesc: chatSequenceHumanDesc,
            userPinned: true,
            currentMessage: messageID,
            generatedAt: prettyDate(),
            generationComplete: true
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            let jsonDict = try await chatService.postDataAsJson(
                try encoder.encode(params),
                endpoint: "/sequences")
            guard jsonDict != nil else { return nil }

            let sequenceID: ChatMessageServerID? = jsonDict!["sequence_id"] as? Int
            return sequenceID
        }
        catch {
            return nil
        }
    }

    func submit(withRetrieval: Bool = false) {
        Task.init {
            submitting = true

            let messageId: ChatMessageServerID? = await chatService.constructUserMessage(promptInEdit)
            guard messageId != nil else {
                submitting = false
                print("[ERROR] Couldn't submit message: \(promptInEdit)")
                return
            }

            let sequenceId: ChatSequenceServerID? =
                await constructUserSequence(id: messageId!)
            guard sequenceId != nil else {
                submitting = false
                print("[ERROR] Couldn't construct sequence from: ChatMessage#\(messageId!)")
                return
            }

            let nextSequence = await chatService.fetchSequence(sequenceId!)
            guard nextSequence != nil else {
                submitting = false
                print("[ERROR] Couldn't fetch sequence information for ChatSequence#\(sequenceId!)")
                return
            }

            pathHost.push(
                chatService.clientModel(for: nextSequence!, inferenceModelSettings: settings)
                    .requestContinue(model: modelSelection?.serverId, withRetrieval: withRetrieval)
                )
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }
}
