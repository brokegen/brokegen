import SwiftUI

let tabBarHeight: CGFloat = 48

let statusBarVPadding: CGFloat = 12
let minStatusBarHeight: CGFloat = statusBarVPadding + 12 + statusBarVPadding

struct MultiMessageView: View {
    @Environment(PathHost.self) private var pathHost
    var viewModel: OneSequenceViewModel
    var settings: CSCSettingsService.SettingsProxy

    @State var isAppActive: Bool = true

    // This is a get-only property, partly to check access, but mostly to see if we can limit SwiftUI update scope.
    var messages: [MessageLike] {
        get { viewModel.sequence.messages }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        @Bindable var settings = settings

        ForEach(messages) { message in
            let messageIndent: CGFloat = {
                if settings.showMessageHeaders || message.messageType == .system || message.messageType == .user {
                    return 0.0
                }

                return settings.messageFontSize * 2
            }()

            let branchAction = {
                if case .serverOnly(let message) = message {
                    if let existingClientModel = viewModel.chatService.chatSequenceClientModels.first(where: {$0.sequence.serverId == message.hostSequenceId}) {
                        pathHost.push(existingClientModel)
                        return
                    }

                    Task { @MainActor in
                        if let sequence = try? await viewModel.chatService.fetchChatSequenceDetails(message.hostSequenceId) {
                            let newClientModel = viewModel.chatService.addClientModel(from: viewModel, for: sequence)
                            pathHost.push(newClientModel)
                        }
                    }
                }
            }

            switch(message.messageType) {
            case .user, .assistant:
                OneMessageView(
                    message,
                    renderMessageContent: viewModel.markdownLookup,
                    branchAction: branchAction,
                    showMessageHeaders: settings.showMessageHeaders,
                    messageFontSize: settings.messageFontSize,
                    expandContent: true,
                    renderAsMarkdown: settings.renderAsMarkdown
                )
                .padding(.leading, messageIndent)
                .id(message)

            case .unknown(_), .serverInfo, .clientInfo:
                OneMessageView(
                    message,
                    showMessageHeaders: settings.showMessageHeaders,
                    messageFontSize: settings.messageFontSize,
                    expandContent: false,
                    renderAsMarkdown: false
                )
                .padding(.leading, messageIndent)
                .id(message)
                .fontDesign(.monospaced)

            case .system, .serverError, .clientError:
                OneMessageView(
                    message,
                    showMessageHeaders: true,
                    messageFontSize: settings.messageFontSize,
                    expandContent: true,
                    renderAsMarkdown: false
                )
                .padding(.leading, messageIndent)
                .id(message)
                .fontDesign(.monospaced)
            }
        }

        if viewModel.responseInEdit != nil {
            let messageIndent = settings.showMessageHeaders ? 0.0 : settings.messageFontSize * 2
            // Disable animation if we're rendering Markdown, because something in MarkdownUI makes it fade really poorly
            // NB This also affects scrollToBottomOnNew
            let shouldAnimate = isAppActive && settings.animateNewResponseText && !settings.renderAsMarkdown

            OneMessageView(
                .temporary(viewModel.responseInEdit!, .assistant),
                stillUpdating: true,
                showMessageHeaders: settings.showMessageHeaders,
                messageFontSize: settings.messageFontSize,
                expandContent: true,
                renderAsMarkdown: settings.renderAsMarkdown
            )
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                self.isAppActive = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.isAppActive = true
            }
            .animation(
                shouldAnimate ? .interactiveSpring : nil,
                value: viewModel.responseInEdit)
            .padding(.leading, messageIndent)
            .id(-1)
        }
    }
}

struct OneSequenceView: View {
    @Environment(PathHost.self) private var pathHost
    @Environment(Templates.self) private var templates
    var viewModel: OneSequenceViewModel
    var settings: CSCSettingsService.SettingsProxy
    @State private var lastScrollOnNewText: Date = Date.distantPast

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false

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
                    @Bindable var viewModel = viewModel

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
                .frame(minWidth: 0)

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
        @Bindable var settings = settings

        if viewModel.showSystemPromptOverride {
            HStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(Color.red.opacity(0.2))

                    ContextualTextInput(
                        desc: "Override system prompt",
                        finalString: $settings.overrideSystemPrompt,
                        historical: templates.recents(
                            type: .systemPromptOverride))
                    {
                        _ = templates.add(
                            content: $0,
                            contentType: .systemPromptOverride,
                            targetModel: viewModel.sequence.serverId)
                    }
                }

                ContextualTextInput(
                    desc: "Override model template",
                    finalString: $settings.overrideModelTemplate,
                    historical: templates.recents(
                        type: .modelTemplate))
                {
                    _ = templates.add(
                        content: $0,
                        contentType: .modelTemplate,
                        targetModel: viewModel.sequence.serverId)
                }
                .monospaced()
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

                ContextualTextInput(
                    desc: "Seed assistant response",
                    finalString: $settings.seedAssistantResponse,
                    historical: templates.recents(
                        type: .assistantResponseSeed))
                {
                    _ = templates.add(
                        content: $0,
                        contentType: .assistantResponseSeed,
                        targetModel: viewModel.sequence.serverId)
                }
            }
        }
    }

    var showLowerVStackOptions: Bool {
        return viewModel.showUiOptions || viewModel.showInferenceOptions || viewModel.showRetrievalOptions
    }

    @ViewBuilder
    var lowerVStackOptions: some View {
        @Bindable var settings = settings

        if viewModel.showUiOptions {
            CSCSettingsView(settings: settings)
        }

        if viewModel.showInferenceOptions {
            GroupBox(content: {
                ContextualTextInput(
                    desc: "Inference options\n(JSON, passed directly to provider)",
                    finalString: $settings.inferenceOptions,
                    historical: templates.recents(
                        type: .inferenceOptions))
                {
                    _ = templates.add(
                        content: $0,
                        contentType: .inferenceOptions,
                        targetModel: viewModel.sequence.serverId)
                }
                .monospaced()
                .frame(width: 480, height: 144)
                .background(Color(.controlBackgroundColor))

            }, label: {
                Text("Provider Inference Options")
                    .font(.system(size: 12).lowercaseSmallCaps())
                    .padding(.top, 24)
            })
        }

        if viewModel.showRetrievalOptions {
            GroupBox(content: {
                VStack(spacing: 24) {
                    Picker("Retrieval policy", selection: $settings.retrievalPolicy) {
                        ForEach(CSInferenceSettings.RetrievalPolicy.allCases) { policy in
                            Text(policy.asUiLabel())
                                .tag(policy)
                        }
                    }

                    ContextualTextInput(
                        desc: "Retrieval-augmented generation (RAG) search args\n(JSON, passed directly to RetrievalPolicy)",
                        finalString: $settings.retrievalSearchArgs,
                        historical: templates.recents(
                            type: .retrievalSearchArgs))
                    {
                        _ = templates.add(
                            content: $0,
                            contentType: .retrievalSearchArgs,
                            targetModel: viewModel.sequence.serverId)
                    }
                    .monospaced()
                    .frame(width: 480, height: 144)
                    .background(Color(.controlBackgroundColor))
                }
                .padding(24)
            }, label: {
                Text("Retrieval options")
                    .font(.system(size: 12).lowercaseSmallCaps())
                    .padding(.top, 24)
            })
        }
    }

    @ViewBuilder
    func lowerTabBar(height lowerTabBarHeight: CGFloat?) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                withAnimation { viewModel.showTextEntryView.toggle() }
            }, label: {
                Image(systemName: viewModel.promptInEdit.isEmpty ? "bubble" : "bubble.fill")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: lowerTabBarHeight)
            })
            .background(viewModel.showTextEntryView ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                withAnimation { viewModel.showUiOptions.toggle() }
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
                withAnimation { viewModel.showSystemPromptOverride.toggle() }
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
                withAnimation { viewModel.showAssistantResponseSeed.toggle() }
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
                withAnimation { viewModel.showInferenceOptions.toggle() }
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
                withAnimation { viewModel.showRetrievalOptions.toggle() }
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
                withAnimation { settings.stayAwakeDuringInference.toggle() }
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
        @Bindable var settings = settings

        if (viewModel.sequence.humanDesc ?? "").isEmpty {
            Text(viewModel.sequence.displayRecognizableDesc())
                .font(.title2)
        }
        else {
            Text(viewModel.sequence.humanDesc!)
                .font(.title2)
            Text(viewModel.sequence.displayServerId())
        }

        Section(header: Text("UI Appearance")) {
            Toggle(isOn: $settings.pinChatSequenceDesc) {
                Text("Keep chat name pinned to top of window")
                Image(systemName: settings.pinChatSequenceDesc ? "pin" : "pin.slash")
            }

            Toggle(isOn: $settings.showMessageHeaders) {
                Text("Show message headers")
            }

            Toggle(isOn: $settings.renderAsMarkdown) {
                Text("Render message content as markdown")
                Image(systemName: settings.renderAsMarkdown ? "doc.richtext.fill" : "doc.richtext")
            }

            Toggle(isOn: $settings.showOFMPicker) {
                Text("Show InferenceModel override picker")
            }
        }

        Section(header: Text("UI Performance Tweaks (global)")) {
            Toggle(isOn: $settings.responseBufferFlush) {
                Text("Buffer inference output\n")
                + Text(
                    viewModel.settings.responseBufferFlush
                    ? "update every \(viewModel.settings.responseBufferFlushFrequencyMsec) msec"
                    : "update every \(PersistentDefaultCSUISettings.default_responseBufferFlushFrequencyMsec) msec"
                )
                .font(.subheadline)
                .foregroundStyle(Color(.disabledControlTextColor))
            }

            Toggle(isOn: $settings.scrollOnNewText) {
                Text("Scroll to bottom of window on new response text\n")
                + Text(
                    viewModel.settings.scrollOnNewText
                    ? "scroll every \(viewModel.settings.scrollOnNewTextFrequencyMsec) msec"
                    : "scroll every \(PersistentDefaultCSUISettings.default_scrollOnNewTextFrequencyMsec) msec"
                )
                .font(.subheadline)
                .foregroundStyle(Color(.disabledControlTextColor))
            }

            Toggle(isOn: $settings.animateNewResponseText) {
                Text("Animate (fade in) new response text")
            }
        }

        Section(header: Text("Server-Side Chat Data")) {
            Button {
                viewModel.chatService.pin(
                    sequenceId: viewModel.sequence.serverId,
                    pinned: !viewModel.sequence.userPinned)
            } label: {
                Toggle(isOn: .constant(viewModel.sequence.userPinned)) {
                    Text("Pin to sidebar")
                }
            }

            Button {
                // Keep the chat name pinned if we're setting a name for the first time.
                // This is a half-measure that sort of informs the user we received the autoname request.
                if (viewModel.sequence.humanDesc ?? "").isEmpty {
                    viewModel.settings.pinChatSequenceDesc = true
                }

                Task.detached { @MainActor in
                    _ = try? await viewModel.chatService.autonameBlocking(sequenceId: viewModel.sequence.serverId, preferredAutonamingModel: viewModel.appSettings.preferredAutonamingModel?.serverId)
                }
            } label: {
                let subtitle: String = {
                    viewModel.appSettings.preferredAutonamingModel == nil
                    ? (viewModel.appSettings.stillPopulating
                       ? "disabled, still loading"
                       : "disabled, set a model in settings")
                    : "\(viewModel.appSettings.preferredAutonamingModel!)"
                }()

                Text("Autoname\n")
                + Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(.disabledControlTextColor))
            }
            .disabled(viewModel.appSettings.preferredAutonamingModel == nil)

            Divider()

            Button {
                viewModel.refreshSequenceData()
            } label: {
                Image(systemName: "arrow.clockwise")
                Text("Refresh sequence data from server")
            }
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

                @Bindable var viewModel = viewModel

                OFMPicker(
                    boxLabel: "Override model for new messages:",
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
        @Bindable var settings = settings

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

                                    MultiMessageView(
                                        viewModel: viewModel,
                                        settings: settings)
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
                        /// - Set a min height so we don't accidentally make a 0-height SplitView pane.
                        /// - Also, set this in a way proportional to the upper VStack,
                        ///   since that's what VSplitView uses to read proportions.
                        .frame(minHeight: 144)
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
        .temporary(TemporaryChatMessage(role: "user", content: "First message", createdAt: Date.distantPast), .user),
        .temporary(TemporaryChatMessage(role: "clown", content: "Second message", createdAt: Date.distantPast)),
        .temporary(TemporaryChatMessage(role: "user", content: "Third message", createdAt: Date.now), .user),
        .temporary(TemporaryChatMessage(role: "user", content: "Fourth message", createdAt: Date(timeIntervalSinceNow: +5)), .user)
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
