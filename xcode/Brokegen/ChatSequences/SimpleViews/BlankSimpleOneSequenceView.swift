import SwiftUI

struct BlankSimpleOneSequenceView: View {
    @Environment(PathHost.self) private var pathHost
    @Environment(BlankSequenceViewModel.self) var viewModel

    @FocusState private var focusTextInput: Bool
    @State private var showContinuationModelPicker: Bool = false
    @State var waitingForNavigation: Bool = false

    var noInferenceModelSelected: Bool {
        return viewModel.continuationInferenceModel == nil && viewModel.appSettings.defaultInferenceModel == nil
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

    func statusBar(_ statusText: String) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(statusText)
                .foregroundStyle(Color(.disabledControlTextColor))
                .lineSpacing(9)
                .layoutPriority(0.2)

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
        .padding(.vertical, statusBarVPadding)
        .background(BackgroundEffectView().ignoresSafeArea())
    }

    var textEntryView: some View {
        HStack(spacing: 0) {
            @Bindable var viewModel = viewModel

            InlineTextInput($viewModel.promptInEdit, isFocused: $focusTextInput)
                .focused($focusTextInput)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.focusTextInput = true
                    }
                }

            Group {
                let aioButtonName: String = {
                    if viewModel.submitting {
                        return "stop.fill"
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

                        self.requestStartAndTransfer(withRetrieval: false)
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
            .frame(alignment: .center)
            .padding([.leading, .trailing], 12)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
    }

    var body: some View {
        GeometryReader { geometry in
            VSplitView {
                VStack(spacing: 0) {
                    @Bindable var viewModel = viewModel

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
                    statusBar(viewModel.submitting ? "Submitting ChatMessage + Sequence" : "Ready")
                        .frame(minHeight: minStatusBarHeight)

                    textEntryView
                        .frame(minHeight: 24)
                        .fontDesign(viewModel.settings.textEntryFontDesign)
                }
            }
            .onAppear {
                if noInferenceModelSelected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation { viewModel.settings.showOFMPicker = true }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(BackgroundEffectView().ignoresSafeArea())
            .navigationTitle("Drafting new chat")
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
}
