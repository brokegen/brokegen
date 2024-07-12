import SwiftUI

struct BlankProSequenceView: View {
    @EnvironmentObject private var pathHost: PathHost
    @EnvironmentObject var viewModel: BlankSequenceViewModel

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false

    @FocusState private var focusSystemPromptOverride: Bool
    @FocusState private var focusModelTemplateOverride: Bool
    @FocusState private var focusAssistantResponseSeed: Bool

    var noInferenceModelSelected: Bool {
        return viewModel.continuationInferenceModel == nil && viewModel.appSettings.defaultInferenceModel == nil
    }

    @ViewBuilder
    var submitButtons: some View {
        let saveButtonDisabled: Bool = viewModel.submitting || viewModel.promptInEdit.isEmpty

        Button(action: {
            Task {
                let constructedSequence: ChatSequence? = await viewModel.requestSave()
                if constructedSequence != nil {
                    DispatchQueue.main.sync {
                        viewModel.chatSettingsService.registerSettings(viewModel.settings, for: constructedSequence!.serverId)

                        let newViewModel: OneSequenceViewModel = viewModel.chatService.addClientModel(fromBlank: viewModel, for: constructedSequence!)

                        pathHost.push(newViewModel)

                        // Once we've successfully transferred the info to a different view, clear it out for if the user starts a new chat.
                        // Only some settings, though, since most of the other ones tend to get reused.
                        viewModel.humanDesc = nil
                        viewModel.promptInEdit = ""
                        viewModel.submitting = false
                        viewModel.submittedAssistantResponseSeed = nil
                        viewModel.serverStatus = nil
                    }
                }
            }
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

        if viewModel.settings.showSeparateRetrievalButton {
            let retrievalButtonDisabled: Bool = {
                if viewModel.submitting {
                    return true
                }

                return viewModel.promptInEdit.isEmpty && !viewModel.settings.allowContinuation
            }()

            Button(action: {
                if noInferenceModelSelected {
                    if !viewModel.settings.showOIMPicker {
                        withAnimation { viewModel.settings.showOIMPicker = true }
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
            else {
                return viewModel.promptInEdit.isEmpty && !viewModel.settings.allowContinuation
            }
        }()

        Button(action: {
            if viewModel.submitting {
                viewModel.stopSubmit(userRequested: true)
            }
            else {
                if noInferenceModelSelected {
                    if !viewModel.settings.showOIMPicker {
                        withAnimation { viewModel.settings.showOIMPicker = true }
                    }
                    else {
                        withAnimation { showContinuationModelPicker = true }
                    }
                    return
                }

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
        .foregroundStyle(
            aioButtonDisabled
            ? Color(.disabledControlTextColor)
            : Color.accentColor)
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
                    .animation(.snappy(duration: 0.2))
                }
                .padding(.leading, 24)
                .padding(.trailing, 12)
            }
        }
    }

    var showStatusBar: Bool {
        return viewModel.displayServerStatus != nil || viewModel.submitting
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

            if viewModel.submitting {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 144)
                    .layoutPriority(0.2)
            }
        }
        .padding([.leading, .trailing], 18)
        .padding([.top, .bottom], 12)
        .background(BackgroundEffectView().ignoresSafeArea())
    }

    var showLowerVStack: Bool {
        return viewModel.showSystemPromptOverride || viewModel.showTextEntryView || viewModel.showAssistantResponseSeed
    }

    @ViewBuilder
    var lowerVStack: some View {
        if viewModel.showSystemPromptOverride {
            HStack {
                ZStack {
                    Rectangle()
                        .fill(Color.red.opacity(0.2))

                    InlineTextInput($viewModel.settings.overrideSystemPrompt, isFocused: $focusSystemPromptOverride)

                    Text("Override System Prompt")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .opacity(viewModel.settings.overrideSystemPrompt.isEmpty ? 1.0 : 0.0)
                }

                ZStack {
                    InlineTextInput($viewModel.settings.overrideModelTemplate, isFocused: $focusModelTemplateOverride)

                    Text("Override Model Template")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .opacity(viewModel.settings.overrideModelTemplate.isEmpty ? 1.0 : 0.0)
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

                InlineTextInput($viewModel.settings.seedAssistantResponse, isFocused: $focusAssistantResponseSeed)

                Text("Seed Assistant Response")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .opacity(viewModel.settings.seedAssistantResponse.isEmpty ? 1.0 : 0.0)
            }
        }
    }

    var showLowerVStackOptions: Bool {
        return viewModel.showUiOptions || viewModel.showInferenceOptions || viewModel.showRetrievalOptions
    }

    @ViewBuilder
    var lowerVStackOptions: some View {
        if viewModel.showUiOptions {
            CSCSettingsView(viewModel.settings)
        }

        if viewModel.showInferenceOptions {
            GroupBox(content: {
                TextEditor(text: $viewModel.settings.inferenceOptions)
                    .frame(width: 360, height: 36)
                    .lineLimit(4...12)
            }, label: {
                Text("inferenceOptions")
            })
        }

        if viewModel.showRetrievalOptions {
            GroupBox(content: {
                TextEditor(text: $viewModel.settings.retrievalPolicy)
                    .frame(width: 360, height: 36)
                    .lineLimit(4...12)

                TextEditor(text: $viewModel.settings.retrievalSearchArgs)
                    .frame(width: 360, height: 36)
                    .lineLimit(4...12)

            }, label: {
                Text("retrievalOptions")
            })
        }
    }

    @ViewBuilder
    var lowerTabBar: some View {
        HStack(spacing: 0) {
            Button(action: {
                viewModel.showTextEntryView.toggle()
            }, label: {
                Image(systemName: viewModel.promptInEdit.isEmpty ? "bubble" : "bubble.fill")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .buttonStyle(.plain)
            .background(viewModel.showTextEntryView ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showUiOptions.toggle()
            }, label: {
                Image(systemName: "gear")
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
            })
            .buttonStyle(.plain)
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
                        .frame(height: 48)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
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
                        .frame(height: 48)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .background(viewModel.showAssistantResponseSeed ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showInferenceOptions.toggle()
            }, label: {
                Text("Inference Options")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .background(viewModel.showInferenceOptions ? Color(.selectedControlColor) : Color(.clear))

            Button(action: {
                viewModel.showRetrievalOptions.toggle()
            }, label: {
                Text("Retrieval Options")
                    .lineLimit(1...3)
                    .font(.system(size: 12))
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
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
                .frame(height: 48)
            })
            .help("Keep macOS system awake during an inference request")
            .buttonStyle(.plain)
        }
        .toggleStyle(.button)
        .font(.system(size: 24))
        .frame(height: tabBarHeight)
    }

    @ViewBuilder
    var contextMenuItems: some View {
        Text(viewModel.displayHumanDesc)

        Divider()

        Section(header: Text("UI Options")) {
            Toggle(isOn: $viewModel.settings.pinChatSequenceDesc) {
                Text("Pin chat name to top of window")
            }

            Toggle(isOn: $viewModel.settings.showMessageHeaders) {
                Text("Show message headers in the UI")
            }

            Toggle(isOn: $viewModel.settings.renderAsMarkdown) {
                Text("Render message content as markdown")
            }

            Toggle(isOn: $viewModel.settings.scrollToBottomOnNew) {
                Text("Scroll to bottom of window on new messages")
            }

            Toggle(isOn: $viewModel.settings.showOIMPicker) {
                Text("Show InferenceModel override picker")
            }
        }
    }

    @ViewBuilder
    func ofmPicker(_ geometry: GeometryProxy) -> some View {
        VStack(alignment: .center, spacing: 0) {
            if viewModel.appSettings.stillPopulating {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)
            }

            HStack(alignment: .center, spacing: 0) {
                Spacer()

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
                .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)

                Spacer()
            }
        }
        .padding(.top, 240)
        .padding(.bottom, 120)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VSplitView {
                    VStack(spacing: 0) {
                        if viewModel.settings.pinChatSequenceDesc {
                            ChatNameReadOnly(
                                Binding(
                                    get: { viewModel.displayHumanDesc },
                                    set: { _, _ in }),
                                pinChatName: $viewModel.settings.pinChatSequenceDesc)
                            .id("sequence title")
                        }

                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 0) {
                                    if !viewModel.settings.pinChatSequenceDesc {
                                        ChatNameReadOnly(
                                            Binding(
                                                get: { viewModel.displayHumanDesc },
                                                set: { _, _ in }),
                                            pinChatName: $viewModel.settings.pinChatSequenceDesc)
                                        .id("sequence title")
                                    }

                                    if viewModel.settings.showOIMPicker {
                                        ofmPicker(geometry)
                                    }
                                } // LazyVStack
                            } // ScrollView
                            .defaultScrollAnchor(.bottom)
                            .contextMenu {
                                contextMenuItems
                            }
                        }
                    }
                    .frame(minHeight: 240)

                    // This is a separate branch, because otherwise the statusBar is resizeable, which we don't really want.
                    if showStatusBar && !showLowerVStack {
                        statusBar
                            .frame(minHeight: statusBarHeight)
                            .frame(maxHeight: statusBarHeight)
                    }
                    else if showStatusBar || showLowerVStack {
                        VStack(spacing: 0) {
                            if showStatusBar {
                                statusBar
                                    .frame(minHeight: statusBarHeight)
                                    .frame(maxHeight: statusBarHeight)
                            }

                            if showLowerVStack {
                                lowerVStack
                                    .frame(minHeight: 72)
                            }
                        }
                    }

                    if showLowerVStackOptions {
                        GeometryReader { optionsGeometry in
                            ScrollView {
                                VFlowLayout(spacing: 24) {
                                    lowerVStackOptions
                                }
                            }
                            .frame(width: optionsGeometry.size.width)
                            .frame(idealHeight: 240)
                        }
                    }

                    lowerTabBar
                }
            }
            .onAppear {
                if noInferenceModelSelected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation { viewModel.settings.showOIMPicker = true }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(BackgroundEffectView().ignoresSafeArea())
            .navigationTitle("Drafting new chat")
        }
    }

    func requestStartAndTransfer(withRetrieval: Bool) {
        Task {
            let constructedSequence: ChatSequence? = await viewModel.requestSave()
            if constructedSequence != nil {
                DispatchQueue.main.async {
                    viewModel.chatSettingsService.registerSettings(viewModel.settings, for: constructedSequence!.serverId)

                    let newViewModel: OneSequenceViewModel = viewModel.chatService.addClientModel(fromBlank: viewModel, for: constructedSequence!)
                    let continuedModel = newViewModel.requestContinue(model: newViewModel.continuationInferenceModel?.serverId ?? viewModel.appSettings.defaultInferenceModel?.serverId, withRetrieval: withRetrieval)

                    pathHost.push(continuedModel)

                    // Once we've successfully transferred the info to a different view, clear it out for if the user starts a new chat.
                    // Only some settings, though, since most of the other ones tend to get reused.
                    viewModel.humanDesc = nil
                    viewModel.promptInEdit = ""
                    viewModel.submitting = false
                    viewModel.submittedAssistantResponseSeed = nil
                    viewModel.serverStatus = nil
                }
            }
        }
    }
}
