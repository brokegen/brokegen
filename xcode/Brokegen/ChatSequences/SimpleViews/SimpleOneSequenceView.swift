import Combine
import SwiftUI

struct SimpleOneSequenceView: View {
    @ObservedObject var viewModel: OneSequenceViewModel
    @ObservedObject var settings: CSCSettingsService.SettingsProxy
    @State private var lastScrollOnNewText: Date = Date.distantPast

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
        .padding(.horizontal, 18)
        .padding(.vertical, statusBarVPadding)
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
                                    SimpleOneMessageView(message)
                                        .id(message)
                                }
                                .fontDesign(settings.messageFontDesign)

                                if viewModel.responseInEdit != nil {
                                    SimpleOneMessageView(.temporary(viewModel.responseInEdit!), stillUpdating: true)
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

                VStack(spacing: 0) {
                    statusBar(viewModel.displayServerStatus ?? "Ready")
                        .frame(minHeight: minStatusBarHeight)

                    textEntryView
                        .frame(minHeight: 24)
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
    return SimpleOneSequenceView(viewModel)
}
