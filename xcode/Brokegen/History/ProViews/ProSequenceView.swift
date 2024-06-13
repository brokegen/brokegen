import SwiftUI

let tabBarHeight: CGFloat = 48

struct ProSequenceView: View {
    @ObservedObject var viewModel: ChatSequenceClientModel
    @Bindable var settings: CombinedCSCSettings

    @FocusState private var focusTextInput: Bool
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
        }
    }

    @State private var showTextEntryView: Bool = true
    @State private var showUiOptions: Bool = false
    @State private var showInferenceOptions: Bool = false
    @State private var showRetrievalOptions: Bool = false
    @State private var stayAwakeOnInference: Bool = true

    @State private var showSystemPromptOverride: Bool = false
    @FocusState private var focusSystemPromptOverride: Bool
    @State private var showAssistantResponseSeed: Bool = false
    @FocusState private var focusAssistantResponseSeed: Bool

    @ViewBuilder var lowerVStack: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(viewModel.displayedStatus ?? "Ready")
                .foregroundStyle(Color(.disabledControlTextColor))
                .lineSpacing(9)
                .layoutPriority(0.2)

            Spacer()

            if viewModel.submitting || viewModel.responseInEdit != nil {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
                    .layoutPriority(0.2)
            }
        }
        .padding([.leading, .trailing], 18)
        .padding([.top, .bottom], 12)
        .frame(minHeight: 36)
        .background(BackgroundEffectView().ignoresSafeArea())

        if showSystemPromptOverride {
            ZStack {
                Rectangle()
                    .fill(Color.red.opacity(0.2))

                InlineTextInput(settings.overrideSystemPrompt(), allowNewlineSubmit: .constant(false), isFocused: $focusSystemPromptOverride) {}

                Text("Override System Prompt")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .opacity(settings.overrideSystemPrompt().wrappedValue.isEmpty ? 1.0 : 0.0)
            }
        }

        if showTextEntryView {
            textEntryView
                .background(inputBackgroundStyle)
        }

        if showAssistantResponseSeed {
            ZStack {
                Rectangle()
                    .fill(Color.blue.opacity(0.2))

                InlineTextInput(settings.seedAssistantResponse(), allowNewlineSubmit: .constant(false), isFocused: $focusAssistantResponseSeed) {}

                Text("Seed Assistant Response")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .opacity(settings.seedAssistantResponse().wrappedValue.isEmpty ? 1.0 : 0.0)
            }
        }
    }

    @ViewBuilder var lowerVStackOptions: some View {
        if showUiOptions || showInferenceOptions || showRetrievalOptions {
            ScrollView {
                VFlowLayout(spacing: 24) {
                    if showUiOptions {
                        // Tab.uiOptions
                        ChatSequenceSettingsView(globalSettings: $viewModel.globalSequenceSettings, settings: $viewModel.sequenceSettings)
                    }

                    // Tab.modelOptions
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
    }

    @ViewBuilder var lowerTabBar: some View {
        // Tab bar
        HStack(spacing: 0) {
            Button(action: {
                showTextEntryView = !showTextEntryView
            }, label: {
                Image(systemName: viewModel.promptInEdit.isEmpty ? "bubble" : "bubble.fill")
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
                Image(systemName: "person.badge.shield.checkmark")
                    .foregroundStyle(showSystemPromptOverride ? .red : Color(.controlTextColor))
                    .padding(.leading, 12)
                    .padding(.trailing, -12)

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
                showAssistantResponseSeed = !showAssistantResponseSeed
            }, label: {
                Image(systemName: settings.seedAssistantResponse().wrappedValue.isEmpty ? "bubble.right" : "bubble.right.fill")
                    .foregroundStyle(showAssistantResponseSeed ? .blue : Color(.controlTextColor))
                    .padding(.leading, 12)
                    .padding(.trailing, -12)

                Text("Response Seed")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .background(showAssistantResponseSeed ? Color(.selectedControlColor) : Color(.clear))

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
        .frame(height: tabBarHeight)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VSplitView {
                    VStack(spacing: 0) {
                        if viewModel.pinSequenceTitle {
                            ChatNameReadOnly(
                                Binding(
                                    get: { viewModel.displayHumanDesc },
                                    set: { _, _ in }),
                                pinChatName: $viewModel.pinSequenceTitle)
                            .id("sequence title")
                        }

                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                if !viewModel.pinSequenceTitle {
                                    ChatNameReadOnly(
                                        Binding(
                                            get: { viewModel.displayHumanDesc },
                                            set: { _, _ in }),
                                        pinChatName: $viewModel.pinSequenceTitle)
                                    .id("sequence title")
                                }

                                ForEach(viewModel.sequence.messages) { message in
                                    ProMessageView(message)
                                }

                                if viewModel.responseInEdit != nil {
                                    ProMessageView(viewModel.responseInEdit!, stillUpdating: true)
                                }
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
                    }
                    .frame(minHeight: 80)

                    let maxInputHeight = {
                        if splitViewLoaded || showSystemPromptOverride || showAssistantResponseSeed {
                            geometry.size.height * 0.7
                        }
                        else {
                            geometry.size.height * 0.2
                        }
                    }()

                    VStack(spacing: 0) {
                        lowerVStack
                    }
                        .frame(minHeight: 180 - tabBarHeight, maxHeight: max(180, maxInputHeight) - tabBarHeight)

                    lowerVStackOptions
                        .frame(maxWidth: .infinity)
                }

                lowerTabBar
                    .frame(maxWidth: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(BackgroundEffectView().ignoresSafeArea())
            .navigationTitle(viewModel.displayHumanDesc)
            .navigationSubtitle(
                viewModel.sequence.serverId != nil
                ? "ChatSequence#\(viewModel.sequence.serverId!)"
                : "")
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct Parameters: Codable {
        let humanDesc: String?
        let userPinned: Bool
        var messages: [Message] = []
    }

    let parameters = Parameters(
        humanDesc: "xcode preview",
        userPinned: true,
        messages: []
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

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
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
