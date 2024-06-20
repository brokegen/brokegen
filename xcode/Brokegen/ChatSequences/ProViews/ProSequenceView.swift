import SwiftUI

let tabBarHeight: CGFloat = 48

struct ProSequenceView: View {
    @ObservedObject var viewModel: OneSequenceViewModel
    @ObservedObject var settings: CSCSettingsService.SettingsProxy

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false
    @State private var splitViewLoaded: Bool = false
    @State private var modelPickerHovered: Bool = false

    @FocusState private var focusSystemPromptOverride: Bool
    @FocusState private var focusModelTemplateOverride: Bool
    @FocusState private var focusAssistantResponseSeed: Bool

    init(_ viewModel: OneSequenceViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    var textEntryView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                InlineTextInput($viewModel.promptInEdit, allowNewlineSubmit: settings.allowNewlineSubmit, isFocused: $focusTextInput) {
                    if viewModel.sequence.serverId == nil {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            _ = viewModel.requestStart(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                        }
                        else {
                            _ = viewModel.requestStart(model: viewModel.continuationInferenceModel?.serverId)
                        }
                    }
                    else if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            _ = viewModel.requestContinue(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                        }
                        else {
                            _ = viewModel.requestContinue(model: viewModel.continuationInferenceModel?.serverId)
                        }
                    }
                    else {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            viewModel.requestExtend(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                        }
                        else {
                            viewModel.requestExtend(model: viewModel.continuationInferenceModel?.serverId)
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
                    let retrievalButtonDisabled: Bool = {
                        if viewModel.submitting || viewModel.responseInEdit != nil {
                            return true
                        }

                        return viewModel.promptInEdit.isEmpty && !settings.allowContinuation
                    }()

                    Button(action: {
                        if viewModel.sequence.serverId == nil {
                            _ = viewModel.requestStart(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                        }
                        else if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                            _ = viewModel.requestContinue(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                        }
                        else {
                            viewModel.requestExtend(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: true)
                        }
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
                            if viewModel.sequence.serverId == nil {
                                _ = viewModel.requestStart(model: viewModel.continuationInferenceModel?.serverId)
                            }
                            else if viewModel.promptInEdit.isEmpty {
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
                            if viewModel.sequence.serverId == nil {
                                _ = viewModel.requestStart(model: viewModel.continuationInferenceModel?.serverId, withRetrieval: settings.forceRetrieval)
                            }
                            else if viewModel.promptInEdit.isEmpty {
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
        return viewModel.displayServerStatus != nil || viewModel.submitting || viewModel.responseInEdit != nil
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

            if viewModel.submitting || viewModel.responseInEdit != nil {
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

                    InlineTextInput($settings.overrideSystemPrompt, allowNewlineSubmit: false, isFocused: $focusSystemPromptOverride) {}

                    Text("Override System Prompt")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .opacity(settings.overrideSystemPrompt.isEmpty ? 1.0 : 0.0)
                }

                ZStack {
                    InlineTextInput($settings.overrideModelTemplate, allowNewlineSubmit: false, isFocused: $focusModelTemplateOverride) {}

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

                InlineTextInput($settings.seedAssistantResponse, allowNewlineSubmit: false, isFocused: $focusAssistantResponseSeed) {}

                Text("Seed Assistant Response")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .opacity(settings.seedAssistantResponse.isEmpty ? 1.0 : 0.0)
            }
        }
    }

    var showLowerVStackOptions: Bool {
        return viewModel.showUiOptions || viewModel.showInferenceOptions || viewModel.showRetrievalOptions
    }

    @ViewBuilder var lowerVStackOptions: some View {
        if viewModel.showUiOptions {
            // Tab.uiOptions
            CSCSettingsView(viewModel, settings: viewModel.settings)
        }

        // Tab.modelOptions
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
                    Image(systemName: "person.badge.shield.checkmark")
                        .foregroundStyle(viewModel.showSystemPromptOverride ? .red : Color(.controlTextColor))
                        .padding(.leading, 12)
                        .padding(.trailing, -12)

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
                    Image(systemName: settings.seedAssistantResponse.isEmpty ? "bubble.right" : "bubble.right.fill")
                        .foregroundStyle(viewModel.showAssistantResponseSeed ? .blue : Color(.controlTextColor))
                        .padding(.leading, 12)
                        .padding(.trailing, -12)

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

    @State private var statusBarHeight: CGFloat = 0
    @State private var lowerVStackHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VSplitView {
                    VStack(spacing: 0) {
                        if settings.pinChatSequenceDesc {
                            ChatNameReadOnly(
                                Binding(
                                    get: { viewModel.displayHumanDesc },
                                    set: { _, _ in }),
                                pinChatName: $settings.pinChatSequenceDesc)
                            .id("sequence title")
                        }

                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    if !settings.pinChatSequenceDesc {
                                        ChatNameReadOnly(
                                            Binding(
                                                get: { viewModel.displayHumanDesc },
                                                set: { _, _ in }),
                                            pinChatName: $settings.pinChatSequenceDesc)
                                        .id("sequence title")
                                    }

                                    ForEach(viewModel.sequence.messages) { message in
                                        let indentMessage = !settings.showMessageHeaders && message.role != "user"

                                        ProMessageView(.legacy(message), showMessageHeaders: settings.showMessageHeaders)
                                            .padding(.leading, indentMessage ? 24.0 : 0.0)
                                    }

                                    if viewModel.responseInEdit != nil {
                                        let indentMessage = !settings.showMessageHeaders

                                        ProMessageView(.legacy(viewModel.responseInEdit!), stillUpdating: true, showMessageHeaders: settings.showMessageHeaders)
                                            .padding(.leading, indentMessage ? 24.0 : 0.0)
                                    }

                                    if settings.showOIMPicker {
                                        HStack(spacing: 0) {
                                            Spacer()

                                            OFMPicker(
                                                boxLabel: "Select a different inference model for next message:",
                                                selectedModelBinding: $viewModel.continuationInferenceModel,
                                                showModelPicker: $showContinuationModelPicker,
                                                geometry: geometry,
                                                allowClear: true)
                                            .frame(maxWidth: 800)
                                            .foregroundStyle(Color(.disabledControlTextColor))
                                            // TODO: We can eventually make this something like pull-to-refresh, putting it relatively far below the fold.
                                            .padding(.bottom, 120)
                                            .padding(.top, max(
                                                120,
                                                geometry.size.height * 0.2
                                            ))
                                            .contentShape(Rectangle())
                                            .onHover { isHovered in
                                                modelPickerHovered = isHovered
                                            }
                                            .layoutPriority(0.2)

                                            Spacer()
                                        }
                                    }
                                }
                            }
                            .defaultScrollAnchor(.bottom)
                            .onAppear {
                                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)

                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    splitViewLoaded = true
                                }
                            }
                            .onChange(of: viewModel.sequence.messages) {
                                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                            }
                            .onChange(of: viewModel.responseInEdit?.content) {
                                // TODO: Replace this with a GeometryReader that merely nudges us, if we're already close to the bottom
                                proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
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
        let viewModel = OneSequenceViewModel(sequence, chatService: chatService, appSettings: AppSettings(), chatSettingsService: CSCSettingsService())

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
        let viewModel = OneSequenceViewModel(sequence, chatService: chatService, appSettings: AppSettings(), chatSettingsService: CSCSettingsService())
        return ProSequenceView(viewModel)
    }
    catch {
        return Text("Failed to construct SequenceViewTwo")
    }
}
