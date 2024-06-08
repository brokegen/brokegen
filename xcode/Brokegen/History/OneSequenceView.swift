import Combine
import CustomTabView
import SwiftUI

let inputBackgroundStyle = Color(.controlBackgroundColor)

enum Tab: String, Hashable, CaseIterable {
    case simple, retrieval, uiOptions, modelOptions, systemOptions
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
            ForEach([Tab.simple, Tab.retrieval], id: \.self) { tab in
                HStack(spacing: 0) {
                    Spacer()
                        .frame(minWidth: 0)
                    Text(tab.rawValue)
                        .layoutPriority(1)
                }
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 32)
                .background(selection == tab
                            ? Color(.selectedControlColor)
                            : inputBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = tab
                    onTabSelection(tab)
                }
                .layoutPriority(0.2)
            }

            Spacer()

            ForEach([Tab.uiOptions, Tab.modelOptions, Tab.systemOptions], id: \.self) { tab in
                HStack(spacing: 0) {
                    Text(tab.rawValue)
                        .layoutPriority(1)
                    Spacer()
                        .frame(minWidth: 0)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 32)
                .background(selection == tab
                            ? Color(.selectedControlColor)
                            : inputBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = tab
                    onTabSelection(tab)
                }
                .layoutPriority(0.2)
            }
        }
        .frame(maxWidth: 120)
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
            VStack(spacing: 0) {
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
                            .disabled(buttonDisabled)
                            .foregroundStyle(
                                buttonDisabled
                                ? Color(.disabledControlTextColor)
                                : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
            }

            // Tab.retrieval
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    InlineTextInput($viewModel.promptInEdit, allowNewlineSubmit: $settings.allowNewlineSubmit, isFocused: $focusTextInput) {
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
                                .disabled(viewModel.promptInEdit.isEmpty && !settings.allowContinuation)
                                .foregroundStyle(viewModel.promptInEdit.isEmpty && !settings.allowContinuation
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
                .background(inputBackgroundStyle)
            }

            // Tab.uiOptions
            ChatSequenceSettingsView(globalSettings: $viewModel.globalSequenceSettings, settings: $viewModel.sequenceSettings)

            // Tab.modelOptions
            VFlowLayout(spacing: 0) {
                GroupBox(content: {
                    TextField("sequenceSettings.overrideSystemPrompt", text: settings.overrideSystemPrompt())
                }, label: {
                    Text("sequenceSettings.overrideSystemPrompt")
                })

                GroupBox(content: {
                    TextField("inferenceOptions", text: settings.inferenceOptions())
                }, label: {
                    Text("inferenceOptions")
                })
            }

            // Tab.systemOptions
            VFlowLayout(spacing: 0) {
                GroupBox(content: {
                    TextEditor(text: settings.overrideSystemPrompt())
                        .frame(width: 360, height: 72)
                        .lineLimit(4...12)
                }, label: {
                    Text("overrideSystemPrompt")
                })

                GroupBox(content: {
                    TextEditor(text: settings.retrieverOptions())
                        .frame(width: 360, height: 72)
                        .lineLimit(4...12)
                }, label: {
                    Text("retrieverOptions")
                })
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
                                    .padding(24)
                                    .padding(.top, 16)
                            }

                            if viewModel.responseInEdit != nil {
                                OneMessageView(viewModel.responseInEdit!, stillUpdating: true)
                                    .padding(24)
                                    .padding(.top, 16)
                            }
                        }
                    }
                    .frame(minHeight: 80)

                    VStack(spacing: 0) {
                        if viewModel.submitting || viewModel.responseInEdit != nil || viewModel.displayedStatus != nil {
                            // TODO: This doesn't seem like the right UI move, but I don't understand colors yet
                            Divider()

                            HStack(spacing: 0) {
                                if viewModel.displayedStatus != nil {
                                    // TODO: Find a way to persist any changes for at least a few seconds
                                    Text(viewModel.displayedStatus ?? "")
                                        .foregroundStyle(Color(.disabledControlTextColor))
                                        .layoutPriority(0.2)
                                }

                                Spacer()

                                if viewModel.submitting || viewModel.responseInEdit != nil {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                        .frame(maxWidth: 120)
                                        .layoutPriority(0.2)
                                }
                            }
                            .padding(.leading, 24)
                            .padding(.trailing, 24)
                            .frame(minHeight: 36)
                        }

                        tabsView
                            .frame(minHeight: 180, maxHeight: max(
                                180,
                                splitViewLoaded ? geometry.size.height * 0.7 : geometry.size.height * 0.2))
                    } // end of entire lower VStack
                    .background(inputBackgroundStyle)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        splitViewLoaded = true
                    }
                }
                .onChange(of: viewModel.sequence.messages) { old, new in
                    proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
                }
                .onChange(of: viewModel.responseInEdit?.content) {
                    // TODO: Replace this with a GeometryReader that merely nudges us, if we're already close to the bottom
                    proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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
