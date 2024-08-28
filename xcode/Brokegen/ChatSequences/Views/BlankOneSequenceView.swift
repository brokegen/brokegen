import SwiftUI


struct BlankOneSequenceView: View {
    @Environment(PathHost.self) private var pathHost
    @Environment(Templates.self) private var templates
    @Environment(BlankSequenceViewModel.self) var viewModel

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false
    @State var waitingForNavigation: Bool = false

    @FocusState private var focusSystemPromptOverride: Bool
    @FocusState private var focusModelTemplateOverride: Bool
    @FocusState private var focusAssistantResponseSeed: Bool
    @FocusState private var focusInferenceOptions: Bool
    @FocusState private var focusRetrievalOptions: Bool

    var noInferenceModelSelected: Bool {
        return viewModel.continuationInferenceModel == nil && viewModel.appSettings.defaultInferenceModel == nil
    }

    @ViewBuilder
    var submitButtons: some View {
        let saveButtonDisabled: Bool = viewModel.submitting || viewModel.promptInEdit.isEmpty

        Button(action: requestSave) {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 32))
        }
        .help("Save message on server, no inference")
        .buttonStyle(.plain)
        .disabled(saveButtonDisabled)
        .foregroundStyle(saveButtonDisabled
                         ? Color(.disabledControlTextColor)
                         : Color.accentColor)

        if viewModel.settings.showSeparateRetrievalButton {
            let retrievalButtonDisabled: Bool = {
                if viewModel.submitting {
                    return true
                }

                return viewModel.promptInEdit.isEmpty && !viewModel.settings.allowContinuation
            }()

            Button(action: {
                if noInferenceModelSelected {
                    if !viewModel.settings.showOFMPicker {
                        withAnimation { viewModel.settings.showOFMPicker = true }
                    }
                    else {
                        withAnimation { showContinuationModelPicker = true }
                    }
                    return
                }

                self.requestStartAndTransfer(withRetrieval: true)
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
            if viewModel.submitting {
                return "stop.fill"
            }

            if !viewModel.settings.showSeparateRetrievalButton && viewModel.settings.forceRetrieval {
                return "arrow.up.doc"
            }

            return "paperplane"
        }()

        let aioButtonDisabled: Bool = {
            if viewModel.submitting {
                return false
            }
            else if waitingForNavigation {
                return true
            }
            else {
                return viewModel.promptInEdit.isEmpty && !viewModel.settings.allowContinuation
            }
        }()

        Button(action: {
            if viewModel.submitting {
                viewModel.stopSubmit(userRequested: true)
            }
            else if waitingForNavigation {
                return
            }
            else {
                if noInferenceModelSelected {
                    if !viewModel.settings.showOFMPicker {
                        withAnimation { viewModel.settings.showOFMPicker = true }
                    }
                    else {
                        withAnimation { showContinuationModelPicker = true }
                    }
                    return
                }

                guard !viewModel.promptInEdit.isEmpty || viewModel.settings.allowContinuation else { return }

                if viewModel.settings.showSeparateRetrievalButton {
                    self.requestStartAndTransfer(withRetrieval: false)
                }
                else {
                    self.requestStartAndTransfer(withRetrieval: viewModel.settings.forceRetrieval)
                }
            }
        }) {
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

                    let useVerticalLayout = geometry.size.height >= 150 + 48
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
        return viewModel.displayServerStatus != nil || viewModel.submitting || waitingForNavigation
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

            if viewModel.submitting || waitingForNavigation {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 144)
                    .layoutPriority(0.2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(BackgroundEffectView().ignoresSafeArea())
    }

    var showLowerVStack: Bool {
        return viewModel.showSystemPromptOverride || viewModel.showTextEntryView || viewModel.showAssistantResponseSeed
    }

    @ViewBuilder
    var lowerVStack: some View {
        @Bindable var viewModel = viewModel

        if viewModel.showSystemPromptOverride {
            HStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(Color.red.opacity(0.2))

                    ContextualTextInput(
                        desc: "Override system prompt",
                        finalString: $viewModel.settings.overrideSystemPrompt,
                        historical: templates.recents(
                            type: .systemPromptOverride))
                    {
                        _ = templates.add(
                            content: $0,
                            contentType: .systemPromptOverride,
                            targetModel: nil)
                    }
                }

                ContextualTextInput(
                    desc: "Override model template",
                    finalString: $viewModel.settings.overrideModelTemplate,
                    historical: templates.recents(
                        type: .modelTemplate))
                {
                    _ = templates.add(
                        content: $0,
                        contentType: .modelTemplate,
                        targetModel: nil)
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
                    finalString: $viewModel.settings.seedAssistantResponse,
                    historical: templates.recents(
                        type: .assistantResponseSeed))
                {
                    _ = templates.add(
                        content: $0,
                        contentType: .assistantResponseSeed,
                        targetModel: nil)
                }
            }
        }
    }

    var showLowerVStackOptions: Bool {
        return viewModel.showUiOptions || viewModel.showInferenceOptions || viewModel.showRetrievalOptions
    }

    @ViewBuilder
    var lowerVStackOptions: some View {
        @Bindable var viewModel = viewModel

        if viewModel.showUiOptions {
            CSCSettingsView(settings: viewModel.settings)
        }

        if viewModel.showInferenceOptions {
            GroupBox(content: {
                ContextualTextInput(
                    desc: "Inference options\n(JSON, passed directly to provider)",
                    finalString: $viewModel.settings.inferenceOptions,
                    historical: templates.recents(
                        type: .inferenceOptions))
                {
                    _ = templates.add(
                        content: $0,
                        contentType: .inferenceOptions,
                        targetModel: nil)
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
                    Picker("Retrieval policy", selection: $viewModel.settings.retrievalPolicy) {
                        ForEach(CSInferenceSettings.RetrievalPolicy.allCases) { policy in
                            Text(policy.asUiLabel())
                                .tag(policy)
                        }
                    }

                    ContextualTextInput(
                        desc: "Retrieval-augmented generation (RAG) search args\n(JSON, passed directly to RetrievalPolicy)",
                        finalString: $viewModel.settings.retrievalSearchArgs,
                        historical: templates.recents(
                            type: .retrievalSearchArgs))
                    {
                        _ = templates.add(
                            content: $0,
                            contentType: .retrievalSearchArgs,
                            targetModel: nil)
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
                    Image(systemName: viewModel.settings.overrideSystemPrompt.isEmpty ? "shield" : "shield.fill")
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
                    Image(systemName: viewModel.settings.seedAssistantResponse.isEmpty ? "bubble.right" : "bubble.right.fill")
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
                viewModel.settings.stayAwakeDuringInference.toggle()
            }, label: {
                Image(systemName:
                        viewModel.currentlyAwakeDuringInference
                      ? (viewModel.settings.stayAwakeDuringInference ? "bolt.fill" : "bolt.slash")
                      : (viewModel.settings.stayAwakeDuringInference ? "bolt" : "bolt.slash"))
                .foregroundStyle(
                    viewModel.currentlyAwakeDuringInference ? .green :
                        viewModel.settings.stayAwakeDuringInference ? Color(.controlTextColor) : .red)
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .frame(height: lowerTabBarHeight)
            })
            .help("Keep macOS system awake during an inference request")
        }
        .frame(height: lowerTabBarHeight)
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .font(.system(size: 24))
        .minimumScaleFactor(0.5)
    }

    @ViewBuilder
    var contextMenuItems: some View {
        @Bindable var viewModel = viewModel

        Text(viewModel.displayHumanDesc)
            .font(.title2)

        Section(header: Text("UI Appearance")) {
            Toggle(isOn: $viewModel.settings.pinChatSequenceDesc) {
                Text("Keep chat name pinned to top of window")
            }

            Toggle(isOn: $viewModel.settings.showMessageHeaders) {
                Text("Show message headers")
            }

            Toggle(isOn: $viewModel.settings.renderAsMarkdown) {
                Image(systemName:
                        viewModel.settings.renderAsMarkdown ? "doc.richtext.fill" : "doc.richtext")
                Text("Render message content as markdown")
            }

            Toggle(isOn: $viewModel.settings.showOFMPicker) {
                Text("Show InferenceModel override picker")
            }
        }

        Section(header: Text("UI Performance Tweaks (global)")) {
            Toggle(isOn: $viewModel.settings.responseBufferFlush) {
                Text("Buffer inference output\n")
                + Text(
                    viewModel.settings.responseBufferFlush
                    ? "update every \(viewModel.settings.responseBufferFlushFrequencyMsec) msec"
                    : "update every \(PersistentDefaultCSUISettings.default_responseBufferFlushFrequencyMsec) msec"
                )
                .font(.subheadline)
                .foregroundStyle(Color(.disabledControlTextColor))
            }

            Toggle(isOn: $viewModel.settings.scrollOnNewText) {
                Text("Scroll to bottom of window on new response text\n")
                + Text(
                    viewModel.settings.scrollOnNewText
                    ? "scroll every \(viewModel.settings.scrollOnNewTextFrequencyMsec) msec"
                    : "scroll every \(PersistentDefaultCSUISettings.default_scrollOnNewTextFrequencyMsec) msec"
                )
                .font(.subheadline)
                .foregroundStyle(Color(.disabledControlTextColor))
            }

            Toggle(isOn: $viewModel.settings.animateNewResponseText) {
                Text("Animate (fade in) new response text")
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

                OFMPicker(
                    boxLabel: viewModel.continuationInferenceModel == nil && viewModel.appSettings.defaultInferenceModel != nil
                    ? "Default inference model:"
                    : "Select an inference model:",
                    selectedModelBinding: Binding(
                        get: { viewModel.continuationInferenceModel ?? viewModel.appSettings.defaultInferenceModel },
                        set: { viewModel.continuationInferenceModel = $0 }),
                    showModelPicker: $showContinuationModelPicker,
                    geometry: geometry,
                    allowClear: viewModel.continuationInferenceModel != nil)
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
        @Bindable var viewModel = viewModel

        GeometryReader { geometry in
            VSplitView {
                VStack(spacing: 0) {
                    ChatNameInput($viewModel.humanDesc)
                        .padding(.bottom, 24)
                        .id("sequence title")

                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                if viewModel.settings.showOFMPicker {
                                    ofmPicker(geometry)
                                }
                            }
                        } // ScrollView
                        .defaultScrollAnchor(.bottom)
                    }
                }
                .frame(minHeight: 240)

                VStack(spacing: 0) {
                    if showStatusBar {
                        statusBar
                            .frame(minHeight: minStatusBarHeight)
                    }

                    if showLowerVStack || showLowerVStackOptions {
                        VSplitView {
                            if showLowerVStack {
                                lowerVStack
                                    .fontDesign(viewModel.settings.textEntryFontDesign)
                                    .frame(minHeight:
                                            (viewModel.showSystemPromptOverride ? 32 : 0)
                                           + (viewModel.showTextEntryView ? 32 : 0)
                                           + (viewModel.showAssistantResponseSeed ? 32 : 0)
                                    )
                            }

                            if showLowerVStackOptions {
                                GeometryReader { optionsGeometry in
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
                                .frame(minHeight: 144)
                            }
                        }
                    }
                }

                lowerTabBar(height: tabBarHeight)
            }
            .onAppear {
                if noInferenceModelSelected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation { viewModel.settings.showOFMPicker = true }
                    }
                }
                else {
                    populateRecents(viewModel.continuationInferenceModel?.serverId)
                }
            }
            .onChange(of: viewModel.continuationInferenceModel?.serverId) { oldValue, newValue in
                populateRecents(newValue)
            }
            .contextMenu {
                contextMenuItems
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(BackgroundEffectView().ignoresSafeArea())
            .navigationTitle("Drafting new chat")
        }
    }

    func requestSave() {
        waitingForNavigation = true

        Task {
            let constructedSequence: ChatSequence? = await viewModel.requestSave()
            if constructedSequence == nil {
                DispatchQueue.main.async {
                    waitingForNavigation = false
                }
            }
            else if constructedSequence != nil {
                DispatchQueue.main.async {
                    viewModel.chatSettingsService.registerSettings(viewModel.settings, for: constructedSequence!.serverId)

                    let newViewModel: OneSequenceViewModel = viewModel.chatService.addClientModel(fromBlank: viewModel, for: constructedSequence!)

                    pathHost.push(newViewModel)

                    viewModel.resetForNewChat()
                }
            }
        }
    }

    func requestStartAndTransfer(withRetrieval: Bool) {
        waitingForNavigation = true

        Task {
            let constructedSequence: ChatSequence? = await viewModel.requestSave()
            if constructedSequence == nil {
                DispatchQueue.main.async {
                    waitingForNavigation = false
                }
            }
            else if constructedSequence != nil {
                DispatchQueue.main.async {
                    viewModel.chatSettingsService.registerSettings(viewModel.settings, for: constructedSequence!.serverId)

                    let newViewModel: OneSequenceViewModel = viewModel.chatService.addClientModel(fromBlank: viewModel, for: constructedSequence!)
                    let continuedModel = newViewModel.requestContinue(model: newViewModel.continuationInferenceModel?.serverId ?? viewModel.appSettings.defaultInferenceModel?.serverId, withRetrieval: withRetrieval)

                    pathHost.push(continuedModel)

                    viewModel.resetForNewChat()
                }
            }
        }
    }

    private func populateRecents(
        _ newValue: FoundationModelRecordID?
    ) {
        if viewModel.settings.inference.overrideSystemPrompt == nil {
            if let content = templates.recents(type: .systemPromptOverride, model: newValue).first?.content {
                viewModel.settings.inference.overrideSystemPrompt = content
                viewModel.showSystemPromptOverride = true
            }
        }

        if viewModel.settings.inference.overrideModelTemplate == nil {
            if let content = templates.recents(type: .modelTemplate, model: newValue).first?.content {
                viewModel.settings.overrideModelTemplate = content
                viewModel.showSystemPromptOverride = true
            }
        }

        if viewModel.settings.inference.seedAssistantResponse == nil {
            if let content = templates.recents(type: .assistantResponseSeed, model: newValue).first?.content {
                viewModel.settings.seedAssistantResponse = content
                viewModel.showAssistantResponseSeed = true
            }
        }
        if viewModel.settings.inference.inferenceOptions == nil {
            if let content = templates.recents(type: .inferenceOptions, model: newValue).first?.content {
                viewModel.settings.inferenceOptions = content
                viewModel.showInferenceOptions = true
            }
        }

        if viewModel.settings.retrievalSearchArgs.isEmpty {
            viewModel.settings.retrievalSearchArgs = templates.recents(type: .retrievalSearchArgs).first?.content ?? ""
        }
    }
}
