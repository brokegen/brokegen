import Combine
import CustomTabView
import SwiftUI

enum Tab: String, Hashable, CaseIterable {
    case simple, retrieval, uiOptions
}

struct ComposeTabsView: View {
    @Binding var selection: Tab
    let onTabSelection: (Tab) -> Void

    init(selection: Binding<Tab>, onTabSelection: @escaping (Tab) -> Void) {
        self._selection = selection
        self.onTabSelection = onTabSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "bubble")
                .padding(12)
                .frame(width: 60)
                .background(selection == Tab.simple
                            ? Color(.selectedControlColor)
                            : inputBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = Tab.simple
                    onTabSelection(Tab.simple)
                }
                .layoutPriority(0.2)

            Image(systemName: "doc.text")
                .padding(12)
                .frame(width: 60)
                .background(selection == Tab.retrieval
                            ? Color(.selectedControlColor)
                            : inputBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = Tab.retrieval
                    onTabSelection(Tab.retrieval)
                }
                .layoutPriority(0.2)

            Spacer()

            Image(systemName: "gear")
                .padding(12)
                .frame(width: 60)
                .background(selection == Tab.uiOptions
                            ? Color(.selectedControlColor)
                            : inputBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = Tab.uiOptions
                    onTabSelection(Tab.uiOptions)
                }
                .layoutPriority(0.2)
        }
        .font(.system(size: 24))
    }
}

struct OneSequenceView: View {
    @ObservedObject var viewModel: ChatSequenceClientModel
    @Bindable var settings: CombinedCSCSettings

    @FocusState var focusTextInput: Bool
    @State private var selectedTab: Tab = .retrieval
    @State private var splitViewLoaded: Bool = false

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
        settings = CombinedCSCSettings(globalSettings: viewModel.globalSequenceSettings, sequenceSettings: viewModel.sequenceSettings)
    }

    var tabsView: some View {
        let composeTabsView = ComposeTabsView(selection: $selectedTab) { tab in
            print("Picked tab \(tab.rawValue)")
        }
            .frame(maxHeight: .infinity)

        return CustomTabView(tabBarView: composeTabsView, tabs: Tab.allCases, selection: selectedTab) {
            // Tab.simple
            HStack(spacing: 0) {
                InlineTextInput(
                    $viewModel.promptInEdit,
                    allowNewlineSubmit: $settings.allowNewlineSubmit,
                    isFocused: $focusTextInput
                ) {
                    if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                        _ = viewModel.requestContinue()
                    }
                    else {
                        viewModel.requestExtend()
                    }
                }
                .focused($focusTextInput)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.focusTextInput = true
                    }
                }
                .backgroundStyle(inputBackgroundStyle)

                let buttonName: String = {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        return "stop.fill"
                    }

                    return "arrowshape.up"
                }()

                let buttonDisabled: Bool = {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        return false
                    }
                    else {
                        if viewModel.promptInEdit.isEmpty {
                            return !settings.allowContinuation
                        }
                        else {
                            return false
                        }
                    }
                }()

                Button(action: {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        viewModel.stopSubmitAndReceive(userRequested: true)
                    }
                    else {
                        if viewModel.promptInEdit.isEmpty {
                            if settings.allowContinuation {
                                _ = viewModel.requestContinue()
                            }
                        }
                        else {
                            viewModel.requestExtend()
                        }
                    }
                }) {
                    Image(systemName: buttonName)
                        .font(.system(size: 32))
                        .padding(12)
                }
                .disabled(buttonDisabled)
                .modifier(ForegroundAccentColor(enabled: !buttonDisabled))
                .buttonStyle(.plain)
            }

            // Tab.retrieval
            HStack(spacing: 0) {
                InlineTextInput(
                    $viewModel.promptInEdit,
                    allowNewlineSubmit: $settings.allowNewlineSubmit,
                    isFocused: $focusTextInput
                ) {
                    if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            _ = viewModel.requestContinue(withRetrieval: true)
                        }
                        else {
                            _ = viewModel.requestContinue()
                        }
                    }
                    else {
                        if !settings.showSeparateRetrievalButton && settings.forceRetrieval {
                            viewModel.requestExtend(withRetrieval: true)
                        }
                        else {
                            viewModel.requestExtend()
                        }
                    }
                }
                .focused($focusTextInput)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.focusTextInput = true
                    }
                }
                .backgroundStyle(inputBackgroundStyle)

                let retrievalButtonDisabled: Bool = {
                    if viewModel.submitting || viewModel.responseInEdit != nil {
                        return true
                    }

                    return viewModel.promptInEdit.isEmpty && !settings.allowContinuation
                }()

                if settings.showSeparateRetrievalButton {
                    Button(action: {
                        if viewModel.promptInEdit.isEmpty && settings.allowContinuation {
                            _ = viewModel.requestContinue(withRetrieval: true)
                        }
                        else {
                            viewModel.requestExtend(withRetrieval: true)
                        }
                    }) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 32))
                            .padding(12)
                    }
                    .disabled(retrievalButtonDisabled)
                    .modifier(ForegroundAccentColor(enabled: !retrievalButtonDisabled))
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
                            if viewModel.promptInEdit.isEmpty {
                                if settings.allowContinuation {
                                    _ = viewModel.requestContinue()
                                }
                                else {}
                            }
                            else {
                                viewModel.requestExtend()
                            }
                        }
                        else {
                            if viewModel.promptInEdit.isEmpty {
                                if settings.allowContinuation {
                                    _ = viewModel.requestContinue(withRetrieval: settings.forceRetrieval)
                                }
                                else {}
                            }
                            else {
                                viewModel.requestExtend(withRetrieval: settings.forceRetrieval)
                            }
                        }
                    }
                }) {
                    Image(systemName: aioButtonName)
                        .font(.system(size: 32))
                        .padding(12)
                        .padding(.trailing, 12)
                        .padding(.leading, -6)
                }
                .disabled(aioButtonDisabled)
                .modifier(ForegroundAccentColor(enabled: !aioButtonDisabled))
                .buttonStyle(.plain)
            }

            // Tab.uiOptions
            ViewThatFits {
                VFlowLayout {
                    ChatSequenceSettingsView(globalSettings: $viewModel.globalSequenceSettings, settings: $viewModel.sequenceSettings)
                }

                ScrollView {
                    VFlowLayout(spacing: 0) {
                        ChatSequenceSettingsView(globalSettings: $viewModel.globalSequenceSettings, settings: $viewModel.sequenceSettings)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .tabBarPosition(.edge(.leading))
        .toggleStyle(.switch)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VSplitView {
                    VStack(spacing: 0) {
                        if viewModel.pinSequenceTitle {
                            HStack(spacing: 0) {
                                Text(viewModel.displayHumanDesc)
                                    .font(.system(size: 36))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                                    .layoutPriority(0.2)

                                Spacer()

                                Button(action: {
                                    viewModel.pinSequenceTitle = false
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

                        ScrollView(.vertical) {
                            if !viewModel.pinSequenceTitle {
                                HStack(spacing: 0) {
                                    Text(viewModel.displayHumanDesc)
                                        .font(.system(size: 36))
                                        .foregroundColor(.gray)
                                        .lineLimit(1...10)
                                        .layoutPriority(0.2)

                                    Spacer()

                                    Button(action: {
                                        viewModel.pinSequenceTitle = true
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
                                OneMessageView(viewModel.responseInEdit!, stillUpdating: true)
                            }
                        }
                    }
                    .frame(minHeight: 80)

                    let maxInputHeight = {
                        if splitViewLoaded || selectedTab == .uiOptions {
                            geometry.size.height * 0.7
                        }
                        else {
                            geometry.size.height * 0.2
                        }
                    }()

                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            // TODO: Find a way to persist any changes for at least a few seconds
                            Text(viewModel.displayedStatus ?? "Ready")
                                .foregroundStyle(Color(.disabledControlTextColor))
                                .lineSpacing(9)
                                .layoutPriority(0.2)

                            Spacer()

                            if viewModel.submitting || viewModel.responseInEdit != nil {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 120)
                                    .layoutPriority(0.2)
                            }
                        }
                        .padding([.leading, .trailing], 18)
                        .padding([.top, .bottom], 12)
                        .frame(minHeight: 36)
                        .background(BackgroundEffectView().ignoresSafeArea())

                        tabsView
                    } // end of entire lower VStack
                    .background(inputBackgroundStyle)
                    .frame(minHeight: 180, maxHeight: max(180, maxInputHeight))
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        splitViewLoaded = true
                    }
                }
                .onChange(of: viewModel.sequence.messages) { old, new in
                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                }
                .onChange(of: viewModel.responseInEdit?.content) {
                    proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
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

#Preview(traits: .fixedLayout(width: 800, height: 1200)) {
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
        let viewModel = ChatSequenceClientModel(sequence, chatService: chatService, inferenceModelSettings: InferenceModelSettings())
        return OneSequenceView(viewModel)
    }
    catch {
        return Text("Failed to construct SequenceViewTwo")
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    VSplitView {
        GeometryReader{geometry in
           HSplitView(){
              Rectangle().foregroundColor(.red).frame(minWidth:200, idealWidth: 200, maxWidth: .infinity)
              HSplitView(){
                  Rectangle().foregroundColor(.black).layoutPriority(1)
                  Rectangle().foregroundColor(.green).frame(minWidth:200, idealWidth: 200, maxWidth: .infinity)
              }.layoutPriority(1)
           }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
