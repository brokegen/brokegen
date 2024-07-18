import Combine
import SwiftUI

struct OneSequenceView: View {
    @ObservedObject var viewModel: OneSequenceViewModel
    @ObservedObject var settings: CSCSettingsService.SettingsProxy

    @FocusState var focusTextInput: Bool
    @State private var splitViewLoaded: Bool = false

    init(_ viewModel: OneSequenceViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
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

            HStack(spacing: 12) {
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
                        HStack(spacing: 0) {
                            Text(viewModel.displayHumanDesc)
                                .font(.system(size: 36))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .layoutPriority(0.2)

                            Spacer()

                            Button(action: {
                                settings.pinChatSequenceDesc = false
                            }) {
                                Image(systemName: "pin")
                                    .font(.system(size: 24))
                                    .padding(12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .id("sequence title")
                        .padding(.bottom, 12)
                        .padding(.leading, 24)
                        .padding(.trailing, 24)
                    }

                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if !settings.pinChatSequenceDesc {
                                    HStack(spacing: 0) {
                                        Text(viewModel.displayHumanDesc)
                                            .font(.system(size: 36))
                                            .foregroundColor(.gray)
                                            .lineLimit(1...10)
                                            .layoutPriority(0.2)

                                        Spacer()

                                        Button(action: {
                                            settings.pinChatSequenceDesc = true
                                        }) {
                                            Image(systemName: "pin.slash")
                                                .font(.system(size: 24))
                                                .padding(12)
                                                .contentShape(Rectangle())
                                                .foregroundStyle(Color(.disabledControlTextColor))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .id("sequence title")
                                    .padding(.bottom, 12)
                                    .padding(.leading, 24)
                                    .padding(.trailing, 24)
                                }

                                ForEach(viewModel.sequence.messages) { message in
                                    OneMessageView(message)
                                }

                                if viewModel.responseInEdit != nil {
                                    OneMessageView(.temporary(viewModel.responseInEdit!), stillUpdating: true)
                                }
                            } // LazyVStack
                        } // ScrollView
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
                            proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 240)

                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 0) {
                        Text(viewModel.displayServerStatus ?? "Ready")
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
                    .frame(minHeight: statusBarHeight)
                    .frame(maxHeight: statusBarHeight)

                    textEntryView
                        .frame(minHeight: 72)
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
