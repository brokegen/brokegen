import SwiftUI

struct ProSequenceView: View {
    @ObservedObject var viewModel: ChatSequenceClientModel
    @Bindable var settings: CombinedCSCSettings

    @FocusState var focusTextInput: Bool
    @State private var splitViewLoaded: Bool = false

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
        settings = CombinedCSCSettings(globalSettings: viewModel.globalSequenceSettings, sequenceSettings: viewModel.sequenceSettings)
    }

    var textEntryView: some View {
        // Tab.retrieval
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                InlineTextInput($viewModel.promptInEdit, allowNewlineSubmit: $settings.allowNewlineSubmit, isFocused: $focusTextInput) {
                    if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            _ = viewModel.requestContinue(withRetrieval: true)
                        }
                        else {
                            _ = viewModel.requestContinue()
                        }
                    }
                    else {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            viewModel.requestExtend(withRetrieval: true)
                        }
                        else {
                            viewModel.requestExtend()
                        }
                    }
                }
                .padding(.leading, -24)
                .focused($focusTextInput)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.focusTextInput = true
                    }
                }
                .backgroundStyle(inputBackgroundStyle)

                if settings.showSeparateRetrievalButton {
                    Button(action: {
                        if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                            _ = viewModel.requestContinue(withRetrieval: true)
                        }
                        else {
                            viewModel.requestExtend(withRetrieval: true)
                        }
                    }) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 32))
                            .disabled(viewModel.promptInEdit.isEmpty && !settings.allowContinuation)
                            .foregroundStyle(viewModel.promptInEdit.isEmpty && !settings.allowContinuation
                                             ? Color(.disabledControlTextColor)
                                             : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                let aioButtonName: String = {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        return "stop.fill"
                    }

                    if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                        return "arrow.up.doc"
                    }

                    return "arrowshape.up"
                }()

                let aioButtonDisabled: Bool = {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        return false
                    }
                    else {
                        return viewModel.promptInEdit.isEmpty && !settings.allowContinuation
                    }
                }()

                Button(action: {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        viewModel.stopSubmitAndReceive(userRequested: true)
                    }
                    else {
                        if settings.showSeparateRetrievalButton {
                            if viewModel.promptInEdit.isEmpty {
                                if settings.allowContinuation {
                                    _ = viewModel.requestContinue()
                                }
                                else {}
                            }
                            else {
                                viewModel.requestExtend()
                            }
                        }
                        else {
                            if viewModel.promptInEdit.isEmpty {
                                if settings.allowContinuation {
                                    _ = viewModel.requestContinue(withRetrieval: settings.forceRetrieval)
                                }
                                else {}
                            }
                            else {
                                viewModel.requestExtend(withRetrieval: settings.forceRetrieval)
                            }
                        }
                    }
                }) {
                    Image(systemName: aioButtonName)
                        .font(.system(size: 32))
                        .disabled(aioButtonDisabled)
                        .foregroundStyle(
                            aioButtonDisabled
                            ? Color(.disabledControlTextColor)
                            : Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .background(inputBackgroundStyle)
        }
    }

    @State private var showTextEntryView: Bool = true
    @State private var showUiOptions: Bool = false
    @State private var showSystemPromptOverride: Bool = false
    @State private var showInferenceOptions: Bool = false
    @State private var showRetrievalOptions: Bool = false
    @State private var stayAwakeOnInference: Bool = true

    @ViewBuilder var lowerVStack: some View {
        if showUiOptions || showSystemPromptOverride || showInferenceOptions || showRetrievalOptions {
            ScrollView {
                VFlowLayout(spacing: 24) {
                    if showUiOptions {
                        // Tab.uiOptions
                        ChatSequenceSettingsView(globalSettings: $viewModel.globalSequenceSettings, settings: $viewModel.sequenceSettings)
                    }

                    // Tab.modelOptions
                    if showSystemPromptOverride {
                        GroupBox(content: {
                            TextEditor(text: settings.overrideSystemPrompt())
                                .frame(width: 360, height: 144)
                                .lineLimit(4...12)
                        }, label: {
                            Text("Override System Prompt")
                        })
                    }

                    if showInferenceOptions {
                        GroupBox(content: {
                            TextEditor(text: settings.inferenceOptions())
                                .frame(width: 360, height: 36)
                                .lineLimit(4...12)
                        }, label: {
                            Text("inferenceOptions")
                        })
                    }

                    if showRetrievalOptions {
                        GroupBox(content: {
                            TextEditor(text: settings.retrieverOptions())
                                .frame(width: 360, height: 36)
                                .lineLimit(4...12)
                        }, label: {
                            Text("retrieverOptions")
                        })
                    }
                }
            }
        }

        // Tab bar
        HStack(spacing: 0) {
            Button(action: {
                showTextEntryView = !showTextEntryView
            }, label: {
                Image(systemName: "bubble.fill")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .background(showTextEntryView ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                showUiOptions = !showUiOptions
            }, label: {
                Image(systemName: "gear")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .background(showUiOptions ? Color(.selectedControlColor) : Color(.clear))

            Divider()
                .padding(.trailing, 12)

            Button(action: {
                showSystemPromptOverride = !showSystemPromptOverride
            }, label: {
                Text("System Prompt")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .background(showSystemPromptOverride ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                showInferenceOptions = !showInferenceOptions
            }, label: {
                Text("Inference Options")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .background(showInferenceOptions ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                showRetrievalOptions = !showRetrievalOptions
            }, label: {
                Text("Retrieval Options")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .background(showRetrievalOptions ? Color(.selectedControlColor) : Color(.clear))

            Spacer()

            Button(action: {
                stayAwakeOnInference = !stayAwakeOnInference
            }, label: {
                Image(systemName: stayAwakeOnInference ? "bolt.horizontal.fill" : "bolt.horizontal")
                    .foregroundStyle(stayAwakeOnInference ? .green : Color(.controlTextColor))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
        .toggleStyle(.button)
        .font(.system(size: 24))
        .frame(height: 48)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VSplitView {
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
                                ProMessageView(message)
                                    .padding(24)
                                    .padding(.top, 16)
                            }

                            if viewModel.responseInEdit != nil {
                                ProMessageView(viewModel.responseInEdit!, stillUpdating: true)
                                    .padding(24)
                                    .padding(.top, 16)
                            }
                        }
                    }
                    .frame(minHeight: 80)

                    VStack(spacing: 0) {
                        HStack(alignment: .bottom, spacing: 0) {
                            Text(viewModel.displayedStatus ?? "Ready")
                                .foregroundStyle(Color(.disabledControlTextColor))
                                .lineSpacing(9)
                                .layoutPriority(0.2)
                                .lineLimit(1...3)

                            Spacer()

                            if viewModel.submitting || viewModel.responseInEdit != nil {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 120)
                                    .layoutPriority(0.2)
                            }
                        }
                        .padding(.leading, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 12)

                        if showTextEntryView {
                            textEntryView
                                .frame(minHeight: 48, maxHeight: geometry.size.height * 0.7)
                        }
                    }

                    lowerVStack
                        .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        splitViewLoaded = true
                    }
                }
                .onChange(of: viewModel.sequence.messages) { old, new in
                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                }
                .onChange(of: viewModel.responseInEdit?.content) {
                    // TODO: Replace this with a GeometryReader that merely nudges us, if we're already close to the bottom
                    proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.linear(duration: 0.3))
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 1200)) {
    let messages: [Message] = [
        Message(role: "user", content: "First message", createdAt: Date.distantPast),
        Message(role: "clown", content: "Second message", createdAt: Date.distantPast),
        Message(role: "user", content: "Third message", createdAt: Date.now),
        Message(role: "user", content: "Fourth message", createdAt: Date(timeIntervalSinceNow: +5))
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
        return ProSequenceView(viewModel)
    }
    catch {
        return Text("Failed to construct SequenceViewTwo")
    }
}
