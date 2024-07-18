import Combine
import SwiftUI

struct OneSequenceView: View {
    @ObservedObject var viewModel: OneSequenceViewModel
    @ObservedObject var settings: CSCSettingsService.SettingsProxy

    @FocusState var focusTextInput: Bool

    init(_ viewModel: OneSequenceViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    func statusBar(_ statusText: String) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(statusText)
                .foregroundStyle(Color(.disabledControlTextColor))
                .lineSpacing(9)
                .layoutPriority(0.2)

            Spacer()

            if viewModel.submitting || viewModel.receiving {
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

    var textEntryView: some View {
        HStack(spacing: 12) {
            InlineTextInput($viewModel.promptInEdit, isFocused: $focusTextInput)
                .focused($focusTextInput)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.focusTextInput = true
                    }
                }

            let aioButtonName: String = {
                if viewModel.submitting || viewModel.receiving {
                    return "stop.fill"
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

            Group {
                Button(action: {
                    print("[TRACE] Detected OneSequenceView submit")

                    if viewModel.submitting || viewModel.receiving {
                        viewModel.stopSubmitAndReceive(userRequested: true)
                    }
                    else {
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

                                ForEach(viewModel.sequence.messages) { message in
                                    OneMessageView(message)
                                        .id(message)
                                }
                                .fontDesign(settings.messageFontDesign)

                                if viewModel.responseInEdit != nil {
                                    OneMessageView(.temporary(viewModel.responseInEdit!), stillUpdating: true)
                                        .animation(settings.animateNewResponseText ? .easeIn : nil, value: viewModel.responseInEdit)
                                        .id(-1)
                                        .fontDesign(settings.messageFontDesign)
                                }

                                // Add a bit of scroll-past-the-bottom space
                                Text("End of messages")
                                    .foregroundStyle(Color(.disabledControlTextColor))
                                    .frame(height: 400)
                                    .frame(maxWidth: .infinity)
                            }
                        } // ScrollView
                        .onAppear {
                            proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                        }
                        .onChange(of: viewModel.sequence.messages) {
                            proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                        }
                        .onChange(of: viewModel.responseInEdit?.content) {
                            if settings.scrollToBottomOnNew {
                                if viewModel.responseInEdit != nil {
                                    proxy.scrollTo(-1, anchor: .bottom)
                                }
                                else {
                                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 240)

                VStack(spacing: 0) {
                    statusBar(viewModel.displayServerStatus ?? "Ready")
                        .frame(minHeight: statusBarHeight)
                        .frame(maxHeight: statusBarHeight)

                    textEntryView
                        .frame(minHeight: 72)
                        .fontDesign(settings.textEntryFontDesign)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(BackgroundEffectView().ignoresSafeArea())
            .navigationTitle(viewModel.displayHumanDesc)
            .navigationSubtitle(viewModel.sequence.displayServerId())
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 1200)) {
    let messages: [MessageLike] = [
        .legacy(Message(role: "user", content: "First message", createdAt: Date.distantPast)),
        .legacy(Message(role: "clown", content: "Second message", createdAt: Date.distantPast)),
        .legacy(Message(role: "user", content: "Third message", createdAt: Date.now)),
        .legacy(Message(role: "user", content: "Fourth message", createdAt: Date(timeIntervalSinceNow: +5)))
    ]
    
    let chatService = ChatSyncService()
    let sequence = ChatSequence(
        serverId: 1,
        humanDesc: "xcode preview",
        userPinned: true,
        messages: messages
    )
    let viewModel = OneSequenceViewModel(sequence, chatService: chatService, appSettings: AppSettings(), chatSettingsService: CSCSettingsService())
    return OneSequenceView(viewModel)
}
