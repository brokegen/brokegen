import SwiftUI

struct BlankOneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    @Environment(PathHost.self) private var pathHost
    @Environment(InferenceModelSettings.self) var settings: InferenceModelSettings
    @EnvironmentObject public var chatSettingsService: CSCSettingsService

    @State var modelSelection: InferenceModel?
    @State var chatSequenceHumanDesc: String = ""
    @State var submitting: Bool = false
    @State var promptInEdit: String = ""

    @State var showModelPicker: Bool
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
                        .padding(.bottom, 24)

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

                    HStack(spacing: 0) {
                        InlineTextInput($promptInEdit, allowNewlineSubmit: chatSettingsService.defaults.allowNewlineSubmit, isFocused: $focusTextInput) {
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
                                .padding(12)
                        }
                        .disabled(submitting || promptInEdit.isEmpty)
                        .modifier(ForegroundAccentColor(enabled: !submitting && !promptInEdit.isEmpty))
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
                                .padding(12)
                                .padding(.trailing, 12)
                                .padding(.leading, -6)
                        }
                        .disabled(!submitting && promptInEdit.isEmpty)
                        .modifier(ForegroundAccentColor(enabled: submitting || !promptInEdit.isEmpty))
                        .buttonStyle(.plain)
                    }
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
            .background(BackgroundEffectView().ignoresSafeArea())
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

    func submit(withRetrieval: Bool = false) {
        Task.init {
            submitting = true

            let messageId: ChatMessageServerID? = try? await chatService.constructChatMessage(from: TemporaryChatMessage(
                role: "user",
                content: promptInEdit,
                createdAt: Date.now
            ))
            guard messageId != nil else {
                submitting = false
                print("[ERROR] Couldn't construct ChatMessage from text: \(promptInEdit)")
                return
            }

            let sequenceId: ChatSequenceServerID? = try? await chatService.constructNewChatSequence(messageId: messageId!, humanDesc: chatSequenceHumanDesc)
            guard sequenceId != nil else {
                submitting = false
                print("[ERROR] Couldn't construct sequence from: ChatMessage#\(messageId!)")
                return
            }

            let nextSequence = try? await chatService.fetchChatSequenceDetails(sequenceId!)
            guard nextSequence != nil else {
                submitting = false
                print("[ERROR] Couldn't fetch details for ChatSequence#\(sequenceId!)")
                return
            }

            pathHost.push(
                chatService.clientModel(for: nextSequence!, inferenceModelSettings: settings, chatSettingsService: chatSettingsService)
                    .requestContinue(model: modelSelection?.serverId, withRetrieval: withRetrieval)
            )
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }
}
