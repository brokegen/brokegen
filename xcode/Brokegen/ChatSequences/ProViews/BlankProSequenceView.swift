import SwiftUI

/// TODO: Class is busted. Every time you send a follow-up message, it's based on the original sequenceId.
struct BlankProSequenceView: View {
    @EnvironmentObject private var pathHost: PathHost
    @EnvironmentObject var viewModel: BlankSequenceViewModel

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false
    @State private var splitViewLoaded: Bool = false

    @FocusState private var focusSystemPromptOverride: Bool
    @FocusState private var focusModelTemplateOverride: Bool
    @FocusState private var focusAssistantResponseSeed: Bool

    @State private var statusBarHeight: CGFloat = 0
    @State private var lowerVStackHeight: CGFloat = 0

    var noInferenceModelSelected: Bool {
        return viewModel.continuationInferenceModel == nil && viewModel.appSettings.defaultInferenceModel == nil
    }

    var textEntryView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                InlineTextInput($viewModel.promptInEdit, allowNewlineSubmit: viewModel.settings.allowNewlineSubmit, isFocused: $focusTextInput) {
                    // If we have no continuation models chosen, show the picker and don't submit nothing.
                    if noInferenceModelSelected {
                        if !viewModel.settings.showOIMPicker {
                            withAnimation { viewModel.settings.showOIMPicker = true }
                        }
                        else {
                            withAnimation { showContinuationModelPicker = true }
                        }
                        return
                    }

                    if !viewModel.settings.showSeparateRetrievalButton && viewModel.settings.forceRetrieval {
                        self.requestStartAndTransfer(withRetrieval: true)
                    }
                    else {
                        self.requestStartAndTransfer(withRetrieval: false)
                    }
                }
                .padding(.leading, -24)
                .focused($focusTextInput)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.focusTextInput = true
                    }
                }

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
                            .disabled(retrievalButtonDisabled)
                            .foregroundStyle(retrievalButtonDisabled
                                             ? Color(.disabledControlTextColor)
                                             : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                let aioButtonName: String = {
                    if viewModel.submitting {
                        return "stop.fill"
                    }

                    if !viewModel.settings.showSeparateRetrievalButton && viewModel.settings.forceRetrieval {
                        return "arrow.up.doc"
                    }

                    return "arrowshape.up"
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

    var showStatusBar: Bool {
        return viewModel.displayServerStatus != nil || viewModel.submitting
    }

    @ViewBuilder var statusBar: some View {
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

    @ViewBuilder var lowerVStack: some View {
        if viewModel.showSystemPromptOverride {
            HStack {
                ZStack {
                    Rectangle()
                        .fill(Color.red.opacity(0.2))

                    InlineTextInput($viewModel.settings.overrideSystemPrompt, allowNewlineSubmit: false, isFocused: $focusSystemPromptOverride) {}

                    Text("Override System Prompt")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .opacity(viewModel.settings.overrideSystemPrompt.isEmpty ? 1.0 : 0.0)
                }

                ZStack {
                    InlineTextInput($viewModel.settings.overrideModelTemplate, allowNewlineSubmit: false, isFocused: $focusModelTemplateOverride) {}

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

                InlineTextInput($viewModel.settings.seedAssistantResponse, allowNewlineSubmit: false, isFocused: $focusAssistantResponseSeed) {}

                Text("Seed Assistant Response")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .opacity(viewModel.settings.seedAssistantResponse.isEmpty ? 1.0 : 0.0)
            }
        }
    }

    var showLowerVStackOptions: Bool {
        return viewModel.showUiOptions || viewModel.showInferenceOptions || viewModel.showRetrievalOptions
    }

    @ViewBuilder var lowerVStackOptions: some View {
        if viewModel.showUiOptions {
            // Tab.uiOptions
            CSCSettingsView(viewModel.settings, sequenceDesc: " for draft")
        }

        // Tab.modelOptions
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

    @ViewBuilder var lowerTabBar: some View {
        // Tab bar
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

    @ViewBuilder var contextMenuItems: some View {
        Text(viewModel.displayHumanDesc)

        Divider()

        Section(header: Text("UI Options")) {
            Button(action: {
                NSApp.keyWindow?.contentViewController?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)),
                    with: nil)
            }, label: {
                Text("Toggle Sidebar")
            })
            .keyboardShortcut("\\", modifiers: [.command])

            Toggle(isOn: $viewModel.settings.pinChatSequenceDesc) {
                Text("Pin chat name to top of window")
            }

            Toggle(isOn: $viewModel.settings.showMessageHeaders) {
                Text("Show message headers in the UI")
            }

            Toggle(isOn: $viewModel.settings.scrollToBottomOnNew) {
                Text("Scroll to bottom of window on new messages")
            }

            Toggle(isOn: $viewModel.settings.showOIMPicker) {
                Text("Show InferenceModel override picker")
            }
        }

        Divider()

        Section(header: Text("Chat Data")) {
            Button {
            } label: {
                Toggle(isOn: .constant(false)) {
                    Text("Pin ChatSequence to sidebar")
                }
            }
            .disabled(true)

            Button {
            } label: {
                Text(
                    "Autoname disabled"
                )
            }
            .disabled(true)
        }
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
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    if !viewModel.settings.pinChatSequenceDesc {
                                        ChatNameReadOnly(
                                            Binding(
                                                get: { viewModel.displayHumanDesc },
                                                set: { _, _ in }),
                                            pinChatName: $viewModel.settings.pinChatSequenceDesc)
                                        .id("sequence title")
                                    }

                                    if viewModel.settings.showOIMPicker {
                                        if viewModel.appSettings.stillPopulating {
                                            ProgressView()
                                                .progressViewStyle(.linear)
                                                .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)
                                        }

                                        HStack(spacing: 0) {
                                            Spacer()

                                            OFMPicker(
                                                boxLabel: "Select an inference model:",
                                                selectedModelBinding: $viewModel.continuationInferenceModel,
                                                showModelPicker: $showContinuationModelPicker,
                                                geometry: geometry,
                                                allowClear: true)
                                            .disabled(viewModel.appSettings.stillPopulating)
                                            .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)
                                            .foregroundStyle(Color(.disabledControlTextColor))
                                            .padding(.bottom, 120)
                                            .padding(.top, max(
                                                120,
                                                geometry.size.height * 0.2
                                            ))
                                            .contentShape(Rectangle())
                                            .layoutPriority(0.2)

                                            Spacer()
                                        }
                                    } // if showOIMPicker
                                } // LazyVStack
                            } // ScrollView
                            .defaultScrollAnchor(.bottom)
                            .contextMenu {
                                contextMenuItems
                            }
                        }
                    }
                    .frame(minHeight: 240)

                    let maxInputHeight = {
                        if splitViewLoaded || showLowerVStack || showLowerVStackOptions {
                            geometry.size.height * 0.7
                        }
                        else {
                            geometry.size.height * 0.2
                        }
                    }()

                    // This is a separate branch, because otherwise the statusBar is resizeable, which we don't really want.
                    if showStatusBar && !showLowerVStack {
                        statusBar
                        // Read and store the "preferred" height of the status bar
                            .background(
                                GeometryReader { statusBarGeometry in
                                    Color.clear
                                        .onAppear {
                                            statusBarHeight = statusBarGeometry.size.height
                                        }
                                }
                            )
                            .frame(minHeight: statusBarHeight)
                            .frame(maxHeight: statusBarHeight)
                    }
                    else if showStatusBar || showLowerVStack {
                        VStack(spacing: 0) {
                            if showStatusBar {
                                statusBar
                                // Read and store the "preferred" height of the status bar
                                    .background(
                                        GeometryReader { statusBarGeometry in
                                            Color.clear
                                                .onAppear {
                                                    statusBarHeight = statusBarGeometry.size.height
                                                }
                                        }
                                    )
                            }

                            if showLowerVStack {
                                lowerVStack
                                    .background(
                                        GeometryReader { lowerVStackGeometry in
                                            Color.clear
                                                .onAppear {
                                                    lowerVStackHeight = lowerVStackGeometry.size.height
                                                }
                                        }
                                    )
                            }
                        }
                        .frame(
                            minHeight: statusBarHeight + max(72, lowerVStackHeight),
                            maxHeight: max(
                                statusBarHeight + max(72, lowerVStackHeight),
                                maxInputHeight - statusBarHeight - lowerVStackHeight
                            ))
                    }

                    if showLowerVStackOptions {
                        GeometryReader { optionsGeometry in
                            ScrollView {
                                VFlowLayout(spacing: 24) {
                                    lowerVStackOptions
                                }
                            }
                            .frame(width: optionsGeometry.size.width)
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
            let constructedSequence: ChatSequence? = await viewModel.requestStart()
            if constructedSequence != nil {
                DispatchQueue.main.async {
                    viewModel.chatSettingsService.registerSettings(viewModel.settings, for: constructedSequence!)

                    let newViewModel: OneSequenceViewModel = viewModel.chatService.addClientModel(fromBlank: viewModel, for: constructedSequence!, withRetrieval: withRetrieval)
                    _ = newViewModel.requestContinue(model: newViewModel.continuationInferenceModel?.serverId ?? viewModel.appSettings.defaultInferenceModel?.serverId, withRetrieval: withRetrieval)

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
    }
}
