import SwiftUI

let tabBarHeight: CGFloat = 48

let statusBarVPadding: CGFloat = 12
let minStatusBarHeight: CGFloat = statusBarVPadding + 12 + statusBarVPadding

struct OneSequenceView: View {
    @EnvironmentObject private var pathHost: PathHost
    @ObservedObject var viewModel: OneSequenceViewModel
    @ObservedObject var settings: CSCSettingsService.SettingsProxy
    @State private var lastScrollOnNewText: Date = Date.distantPast

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false

    @FocusState private var focusSystemPromptOverride: Bool
    @FocusState private var focusModelTemplateOverride: Bool
    @FocusState private var focusAssistantResponseSeed: Bool

    init(_ viewModel: OneSequenceViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    func aioSubmit() {
        print("[TRACE] Detected OneSequenceView.aioSubmit()")

        if viewModel.submitting || viewModel.receiving {
            viewModel.stopSubmitAndReceive(userRequested: true)
        }
        else {
            if settings.showSeparateRetrievalButton {
                if viewModel.promptInEdit.isEmpty {
                    if settings.allowContinuation {
                        _ = viewModel.requestContinue(model: viewModel.continuationInferenceModel?.serverId)
                    }
                    else {}
                }
                else {
                    viewModel.requestExtend(model: viewModel.continuationInferenceModel?.serverId)
                }
            }
            else {
                if viewModel.promptInEdit.isEmpty {
                    if settings.allowContinuation {
                        _ = viewModel.requestContinue(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: settings.forceRetrieval)
                    }
                    else {}
                }
                else {
                    viewModel.requestExtend(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: settings.forceRetrieval)
                }
            }
        }
    }

    @ViewBuilder
    var submitButtons: some View {
        let saveButtonDisabled: Bool = viewModel.submitting || viewModel.receiving || viewModel.promptInEdit.isEmpty

        Button(action: {
            viewModel.requestSave()
        }) {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 32))
        }
        .help("Save message on server, no inference")
        .buttonStyle(.plain)
        .disabled(saveButtonDisabled)
        .foregroundStyle(saveButtonDisabled
                         ? Color(.disabledControlTextColor)
                         : Color.accentColor)

        if settings.showSeparateRetrievalButton {
            let retrievalButtonDisabled: Bool = {
                if viewModel.submitting || viewModel.receiving {
                    return true
                }

                return viewModel.promptInEdit.isEmpty && !settings.allowContinuation
            }()

            Button(action: {
                if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                    _ = viewModel.requestContinue(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                }
                else {
                    viewModel.requestExtend(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                }
            }) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 32))
            }
            .help("Request inference with RAG generation")
            .buttonStyle(.plain)
            .disabled(retrievalButtonDisabled)
            .foregroundStyle(retrievalButtonDisabled
                             ? Color(.disabledControlTextColor)
                             : Color.accentColor)
        }

        let aioButtonName: String = {
            if viewModel.submitting || viewModel.receiving {
                return "stop.fill"
            }

            if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                return "arrow.up.doc"
            }

            return "paperplane"
        }()

        let aioButtonDisabled: Bool = {
            if viewModel.submitting || viewModel.receiving {
                return false
            }
            else {
                return viewModel.promptInEdit.isEmpty && !settings.allowContinuation
            }
        }()

        Button(action: aioSubmit) {
            Image(systemName: aioButtonName)
                .font(.system(size: 32))
        }
        .keyboardShortcut(.return)
        .buttonStyle(.plain)
        .disabled(aioButtonDisabled)
        .modifier(ForegroundAccentColor(enabled: !aioButtonDisabled))
        .id("aio button")
    }

    var textEntryView: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    InlineTextInput($viewModel.promptInEdit, isFocused: $focusTextInput)
                        .padding(.leading, -24)
                        .focused($focusTextInput)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                self.focusTextInput = true
                            }
                        }

                    let useVerticalLayout = geometry.size.height >= 144 + 36
                    let buttonLayout = useVerticalLayout
                    ? AnyLayout(VStackLayout(spacing: 18))
                    : AnyLayout(HStackLayout(spacing: 12))

                    buttonLayout {
                        if useVerticalLayout {
                            Spacer()
                        }
                        submitButtons
                    }
                    .frame(alignment: useVerticalLayout ? .bottom : .center)
                    .padding(.bottom, useVerticalLayout ? 18 : 0)
                    .padding([.leading, .trailing], 12)
                    .animation(.snappy, value: useVerticalLayout)
                }
                .padding(.leading, 24)
                .padding(.trailing, 12)
            }
        }
    }

    var showStatusBar: Bool {
        return viewModel.displayServerStatus != nil || viewModel.submitting || viewModel.receiving
    }

    @ViewBuilder
    var statusBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if viewModel.displayServerStatus != nil {
                Text(viewModel.displayServerStatus!)
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .lineSpacing(9)
                    .layoutPriority(0.2)
            }

            Spacer()

            if viewModel.submitting || viewModel.receiving {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 144)
                    .layoutPriority(0.2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, statusBarVPadding)
        .background(BackgroundEffectView().ignoresSafeArea())
    }

    var showLowerVStack: Bool {
        return viewModel.showSystemPromptOverride || viewModel.showTextEntryView || viewModel.showAssistantResponseSeed
    }

    @ViewBuilder
    var lowerVStack: some View {
        if viewModel.showSystemPromptOverride {
            HStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(Color.red.opacity(0.2))

                    InlineTextInput($settings.overrideSystemPrompt, isFocused: $focusSystemPromptOverride)

                    Text("Override System Prompt")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .opacity(settings.overrideSystemPrompt.isEmpty ? 1.0 : 0.0)
                }

                ZStack {
                    InlineTextInput($settings.overrideModelTemplate, isFocused: $focusModelTemplateOverride)

                    Text("Override Model Template")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .opacity(settings.overrideModelTemplate.isEmpty ? 1.0 : 0.0)
                }
            }
        }

        if viewModel.showTextEntryView {
            textEntryView
                .background(inputBackgroundStyle)
        }

        if viewModel.showAssistantResponseSeed {
            ZStack {
                Rectangle()
                    .fill(Color.blue.opacity(0.2))

                InlineTextInput($settings.seedAssistantResponse, isFocused: $focusAssistantResponseSeed)

                Text("Seed Assistant Response")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .opacity(settings.seedAssistantResponse.isEmpty ? 1.0 : 0.0)
            }
        }
    }

    var showLowerVStackOptions: Bool {
        return viewModel.showUiOptions || viewModel.showInferenceOptions || viewModel.showRetrievalOptions
    }

    @ViewBuilder
    var lowerVStackOptions: some View {
        if viewModel.showUiOptions {
            CSCSettingsView(settings: settings)
        }

        if viewModel.showInferenceOptions {
            GroupBox(content: {
                TextEditor(text: $settings.inferenceOptions)
                    .frame(width: 360, height: 36)
                    .lineLimit(4...12)
            }, label: {
                Text("inferenceOptions")
            })
        }

        if viewModel.showRetrievalOptions {
            GroupBox(content: {
                TextEditor(text: $settings.retrievalPolicy)
                    .frame(width: 360, height: 36)
                    .lineLimit(4...12)

                TextEditor(text: $settings.retrievalSearchArgs)
                    .frame(width: 360, height: 36)
                    .lineLimit(4...12)

            }, label: {
                Text("retrievalOptions")
            })
        }
    }

    @ViewBuilder
    func lowerTabBar(height lowerTabBarHeight: CGFloat?) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                viewModel.showTextEntryView.toggle()
            }, label: {
                Image(systemName: viewModel.promptInEdit.isEmpty ? "bubble" : "bubble.fill")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: lowerTabBarHeight)
            })
            .background(viewModel.showTextEntryView ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showUiOptions.toggle()
            }, label: {
                Image(systemName: "gear")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: lowerTabBarHeight)
            })
            .background(viewModel.showUiOptions ? Color(.selectedControlColor) : Color(.clear))

            Divider()
                .padding(.trailing, 12)

            Button(action: {
                viewModel.showSystemPromptOverride.toggle()
            }, label: {
                HStack(spacing: 0) {
                    Image(systemName: settings.overrideSystemPrompt.isEmpty ? "shield" : "shield.fill")
                        .foregroundStyle(
                            viewModel.showSystemPromptOverride
                            ? .red
                            : Color(.controlTextColor))
                        .padding(.leading, 12)
                        .padding(.trailing, -4)

                    Text("System Prompt")
                        .lineLimit(1...3)
                        .font(.system(size: 12))
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                }
                .frame(height: lowerTabBarHeight)
                .contentShape(Rectangle())
            })
            .background(viewModel.showSystemPromptOverride ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showAssistantResponseSeed.toggle()
            }, label: {
                HStack(spacing: 0) {
                    Image(systemName: settings.seedAssistantResponse.isEmpty ? "bubble.right" : "bubble.right.fill")
                        .foregroundStyle(viewModel.showAssistantResponseSeed ? .blue : Color(.controlTextColor))
                        .padding(.leading, 12)
                        .padding(.trailing, -4)

                    Text("Response Seed")
                        .lineLimit(1...3)
                        .font(.system(size: 12))
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                }
                .frame(height: lowerTabBarHeight)
                .contentShape(Rectangle())
            })
            .background(viewModel.showAssistantResponseSeed ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showInferenceOptions.toggle()
            }, label: {
                Text("Inference Options")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: lowerTabBarHeight)
                    .contentShape(Rectangle())
            })
            .background(viewModel.showInferenceOptions ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showRetrievalOptions.toggle()
            }, label: {
                Text("Retrieval Options")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: lowerTabBarHeight)
                    .contentShape(Rectangle())
            })
            .background(viewModel.showRetrievalOptions ? Color(.selectedControlColor) : Color(.clear))

            Spacer()

            Button(action: {
                settings.stayAwakeDuringInference.toggle()
            }, label: {
                Image(systemName:
                        viewModel.currentlyAwakeDuringInference
                      ? (settings.stayAwakeDuringInference ? "bolt.fill" : "bolt.slash")
                      : (settings.stayAwakeDuringInference ? "bolt" : "bolt.slash"))
                .foregroundStyle(
                    viewModel.currentlyAwakeDuringInference ? .green :
                        settings.stayAwakeDuringInference ? Color(.controlTextColor) : .red)
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .frame(height: lowerTabBarHeight)
            })
            .help("Keep macOS system awake during an inference request")
        }
        // Set a specific size for the tab bar.
        // We still have to set it on the Button's Images, so their backgrounds fill the entire space.
        .frame(height: lowerTabBarHeight)
        .toggleStyle(.button)
        .buttonStyle(.plain)
        // Set the default font size for Images (Text views override with a smaller size)
        .font(.system(size: 24))
        .minimumScaleFactor(0.5)
    }

    @ViewBuilder
    var contextMenuItems: some View {
        Text(viewModel.sequence.displayRecognizableDesc())

        Divider()

        Section(header: Text("UI Appearance")) {
            Toggle(isOn: $settings.pinChatSequenceDesc) {
                Text("Keep chat name pinned to top of window")
            }

            Toggle(isOn: $settings.showMessageHeaders) {
                Text("Show message headers")
            }

            Toggle(isOn: $settings.renderAsMarkdown) {
                Text("Render message content as markdown")
            }

            Toggle(isOn: $settings.showOFMPicker) {
                Text("Show InferenceModel override picker")
            }
        }

        Divider()

        Section(header: Text("UI Performance Tweaks (global)")) {
            Toggle(isOn: $settings.responseBufferFlush) {
                Text(
                    viewModel.settings.responseBufferFlush
                    ? "Buffer inference output: update every \(viewModel.settings.responseBufferFlushFrequencyMsec) msec"
                    : "Buffer inference output: update every \(PersistentDefaultCSUISettings.default_responseBufferFlushFrequencyMsec) msec"
                )
            }

            Toggle(isOn: $settings.scrollOnNewText) {
                Text(
                    viewModel.settings.scrollOnNewText
                    ? "Scroll to bottom of window on new response text: check every \(viewModel.settings.scrollOnNewTextFrequencyMsec) msec"
                    : "Scroll to bottom of window on new response text: check every \(PersistentDefaultCSUISettings.default_scrollOnNewTextFrequencyMsec) msec"
                )
            }

            Toggle(isOn: $settings.animateNewResponseText) {
                Text("Animate (fade in) new response text")
            }
        }

        Divider()

        Section(header: Text("Chat Data")) {
            Button {
                viewModel.chatService.pinChatSequence(viewModel.sequence, pinned: !viewModel.sequence.userPinned)
            } label: {
                Toggle(isOn: .constant(viewModel.sequence.userPinned)) {
                    Text("Pin ChatSequence in sidebar")
                }
            }

            Button {
                _ = viewModel.chatService.autonameChatSequence(viewModel.sequence, preferredAutonamingModel: viewModel.appSettings.preferredAutonamingModel?.serverId)
            } label: {
                Text(viewModel.appSettings.stillPopulating
                     ? "Autoname disabled (still loading)"
                     : (viewModel.appSettings.preferredAutonamingModel == nil
                        ? "Autoname disabled (set a model in settings)"
                        : "Autoname with model: \(viewModel.appSettings.preferredAutonamingModel!.humanId)")
                )
            }
            .disabled(viewModel.appSettings.preferredAutonamingModel == nil)

            Button {
                viewModel.refreshSequenceData()
            } label: {
                Text("Force ChatSequence data refresh...")
            }
        }
    }

    @ViewBuilder
    var messages: some View {
        ForEach(viewModel.sequence.messages) { message in
            let indentMessage = !settings.showMessageHeaders && message.role != "user"
            let branchAction = {
                if case .stored(let message) = message {
                    Task {
                        if let sequence = try? await viewModel.chatService.fetchChatSequenceDetails(message.hostSequenceId) {
                            pathHost.push(
                                viewModel.chatService.clientModel(
                                    for: sequence,
                                    appSettings: viewModel.appSettings,
                                    chatSettingsService: viewModel.chatSettingsService)
                            )
                        }
                    }
                }
            }

            OneMessageView(
                message,
                renderMessageContent: viewModel.lookup,
                branchAction: branchAction,
                showMessageHeaders: settings.showMessageHeaders,
                renderAsMarkdown: $settings.renderAsMarkdown
            )
            .padding(.leading, indentMessage ? 24.0 : 0.0)
            .id(message)
        }

        if viewModel.responseInEdit != nil {
            let messageIndent = settings.showMessageHeaders ? 0.0 : 24.0
            // Disable animation if we're rendering Markdown, because something in MarkdownUI makes it fade really poorly
            // NB This also affects scrollToBottomOnNew
            let shouldAnimate = settings.animateNewResponseText && !settings.renderAsMarkdown

            OneMessageView(
                .temporary(viewModel.responseInEdit!),
                stillUpdating: true,
                showMessageHeaders: settings.showMessageHeaders,
                renderAsMarkdown: $settings.renderAsMarkdown
            )
            .animation(shouldAnimate ? .easeIn : nil, value: viewModel.responseInEdit)
            .padding(.leading, messageIndent)
            .id(-1)
        }
    }

    @ViewBuilder
    func ofmPicker(_ geometry: GeometryProxy) -> some View {
        VStack(alignment: .center) {
            VStack(spacing: 0) {
                if viewModel.appSettings.stillPopulating {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                OFMPicker(
                    boxLabel: "Select an override inference model for next message:",
                    selectedModelBinding: $viewModel.continuationInferenceModel,
                    showModelPicker: $showContinuationModelPicker,
                    geometry: geometry,
                    allowClear: true)
                .disabled(viewModel.appSettings.stillPopulating)
                .foregroundStyle(Color(.disabledControlTextColor))
            }
            .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 240)
        .padding(.bottom, 120)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VSplitView {
                    VStack(spacing: 0) {
                        if settings.pinChatSequenceDesc {
                            ChatNameReadOnly(
                                .constant(viewModel.displayHumanDesc),
                                pinChatName: $settings.pinChatSequenceDesc
                            )
                            .id("sequence title")
                        }

                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 0) {
                                    if !settings.pinChatSequenceDesc {
                                        ChatNameReadOnly(
                                            .constant(viewModel.displayHumanDesc),
                                            pinChatName: $settings.pinChatSequenceDesc
                                        )
                                        .id("sequence title")
                                    }

                                    messages
                                        .fontDesign(settings.messageFontDesign)

                                    // Add a bit of scroll-past-the-bottom space
                                    if !settings.showOFMPicker {
                                        Text("End of messages")
                                            .foregroundStyle(Color(.disabledControlTextColor))
                                            .frame(height: 400)
                                            .frame(maxWidth: .infinity)
                                    }
                                    else {
                                        ofmPicker(geometry)
                                    }
                                }
                            } // ScrollView
                            // When the View appears, scroll to the bottom
                            .defaultScrollAnchor(.bottom)
                            .onAppear {
                                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                                lastScrollOnNewText = Date.now
                            }
                            .onChange(of: viewModel.sequence.messages) {
                                let timeSinceScroll = Date.now.timeIntervalSince(lastScrollOnNewText)
                                let shouldScroll = (
                                    settings.scrollOnNewText
                                    && !settings.renderAsMarkdown
                                    && timeSinceScroll * 1000 > Double(settings.scrollOnNewTextFrequencyMsec)
                                )

                                if shouldScroll {
                                    withAnimation {
                                        proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                                    }
                                    lastScrollOnNewText = Date.now
                                }
                            }
                            .onChange(of: viewModel.responseInEdit?.content) {
                                let timeSinceScroll = Date.now.timeIntervalSince(lastScrollOnNewText)
                                let shouldScroll = (
                                    settings.scrollOnNewText
                                    && !settings.renderAsMarkdown
                                    && timeSinceScroll * 1000 > Double(settings.scrollOnNewTextFrequencyMsec)
                                )

                                if shouldScroll {
                                    if viewModel.responseInEdit != nil {
                                        proxy.scrollTo(-1, anchor: .bottom)
                                        lastScrollOnNewText = Date.now
                                    }
                                    else {
                                        proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                                        lastScrollOnNewText = Date.now
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 240)

                    if showStatusBar || showLowerVStack {
                        VStack(spacing: 0) {
                            if showStatusBar {
                                statusBar
                                    .frame(minHeight: minStatusBarHeight)
                            }

                            if showLowerVStack {
                                lowerVStack
                                    .frame(minHeight: tabBarHeight + 24)
                                    .fontDesign(settings.textEntryFontDesign)
                            }
                        }
                    }

                    if showLowerVStackOptions {
                        GeometryReader { optionsGeometry in
                            // Use ViewThatFits for the case where the options space is so big
                            // there's no need to allow scrolling.
                            ViewThatFits {
                                VStack(alignment: .center) {
                                    VFlowLayout(spacing: 24) {
                                        lowerVStackOptions
                                    }
                                    .frame(width: optionsGeometry.size.width)
                                }
                                .frame(maxWidth: .infinity)

                                ScrollView {
                                    VStack(alignment: .center) {
                                        VFlowLayout(spacing: 24) {
                                            lowerVStackOptions
                                        }
                                        .frame(width: optionsGeometry.size.width)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        // Set a min height so we don't accidentally make a 0-height SplitView pane
                        .frame(minHeight: 72)
                    }

                    lowerTabBar(height: tabBarHeight)
                }
            }
            .contextMenu {
                contextMenuItems
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(BackgroundEffectView().ignoresSafeArea())
            .navigationTitle(viewModel.sequence.displayServerId())
            .navigationSubtitle(viewModel.sequence.displayHumanDesc())
        }
    }
}

#Preview(traits: .fixedLayout(width: 1280, height: 800)) {
    let chatService = ChatSyncService()
    let sequence = ChatSequence(
        serverId: -1,
        humanDesc: "xcode preview",
        userPinned: true,
        messages: []
    )
    let viewModel = OneSequenceViewModel(sequence, chatService: chatService, appSettings: AppSettings(), chatSettingsService: CSCSettingsService())
    viewModel.settings.pinChatSequenceDesc = true

    return OneSequenceView(viewModel)
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    let messages: [MessageLike] = [
        .temporary(TemporaryChatMessage(role: "user", content: "First message", createdAt: Date.distantPast)),
        .temporary(TemporaryChatMessage(role: "clown", content: "Second message", createdAt: Date.distantPast)),
        .temporary(TemporaryChatMessage(role: "user", content: "Third message", createdAt: Date.now)),
        .temporary(TemporaryChatMessage(role: "user", content: "Fourth message", createdAt: Date(timeIntervalSinceNow: +5)))
    ]
    
    let chatService = ChatSyncService()
    let sequence = ChatSequence(
        serverId: 1,
        humanDesc: "xcode preview",
        userPinned: true,
        messages: messages
    )
    let viewModel = OneSequenceViewModel(sequence, chatService: chatService, appSettings: AppSettings(), chatSettingsService: CSCSettingsService())
    viewModel.serverStatus = "[test status to show bar.]\nyeah"
    viewModel.submitting = true

    return OneSequenceView(viewModel)
}