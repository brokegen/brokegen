import SwiftUI

struct BlankOneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    @Environment(PathHost.self) private var pathHost
    @EnvironmentObject public var chatSettingsService: CSCSettingsService
    @EnvironmentObject public var appSettings: AppSettings

    @State var modelSelection: InferenceModel?
    @State var chatSequenceHumanDesc: String = ""
    @State var submitting: Bool = false
    @State var promptInEdit: String = ""

    @State var showModelPicker: Bool
    @FocusState var focusTextInput: Bool
    @State private var splitViewLoaded: Bool = false

    init(alwaysShowModelPicker: Bool = false) {
        _showModelPicker = State(initialValue: alwaysShowModelPicker)
    }

    var body: some View {
        GeometryReader { geometry in
            VSplitView {
                VStack(spacing: 0) {
                    ChatNameInput($chatSequenceHumanDesc)
                        .padding(.bottom, 24)

                    OIMPicker(
                        boxLabel: modelSelection == nil && appSettings.defaultInferenceModel != nil
                        ? "Default Inference Model"
                        : "Inference Model",
                        selectedModelBinding: Binding(
                            get: { modelSelection ?? appSettings.defaultInferenceModel },
                            set: { modelSelection = $0 }),
                        showModelPicker: $showModelPicker,
                        geometry: geometry,
                        allowClear: modelSelection != nil)
                    .frame(maxWidth: 800)
                    .layoutPriority(0.2)

                    Spacer()
                        .frame(minHeight: 0)
                }

                VStack(spacing: 0) {
                    Divider()

                    HStack(spacing: 0) {
                        Text(submitting ? "Submitting ChatMessage + Sequence" : "Ready")
                            .foregroundStyle(Color(.disabledControlTextColor))
                            .layoutPriority(0.2)
                            .lineLimit(1, reservesSpace: true)

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
                    .frame(maxHeight: 36)

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

            DispatchQueue.main.async {
                chatService.updateSequence(withSameId: nextSequence!)
                
                pathHost.push(
                    chatService.clientModel(for: nextSequence!, appSettings: appSettings, chatSettingsService: chatSettingsService)
                        .requestContinue(model: modelSelection?.serverId, withRetrieval: withRetrieval)
                )
            }
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }
}
