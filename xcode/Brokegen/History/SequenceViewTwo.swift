import Combine
import CustomTabView
import SwiftUI

enum Tab: String, Hashable, CaseIterable {
    case simple, pro, proMax, options
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
            ForEach([Tab.simple, Tab.pro, Tab.proMax], id: \.self) { tab in
                HStack(spacing: 0) {
                    Spacer()
                        .frame(minWidth: 0)
                    Text(tab.rawValue)
                        .layoutPriority(1)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 32)
                .background(selection == tab
                            ? Color.accentColor
                            : inputBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = tab
                    onTabSelection(tab)
                }
                .layoutPriority(0.2)
            }

            Spacer()

            Text("options")
                .padding()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 32)
                .background(selection == .options
                            ? Color.accentColor
                            : Color(.controlBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = .options
                    onTabSelection(.options)
                }
                .layoutPriority(0.2)
        }
        .frame(maxWidth: 80)
    }
}

struct SequenceViewTwo: View {
    @ObservedObject var viewModel: ChatSequenceClientModel

    @FocusState var focusTextInput: Bool
    @State private var selectedTab: Tab = .simple

    // per-chat options
    @State var overrideSystemPrompt: String = ""
    @State var retrieverOptions: String = ""

    // entire-model options
    @State var overrideInferenceTemplate: String = ""
    @State var inferenceOptions: String = ""

    // UI options
    // @AppStorage("allowContinuation")
    @State var allowContinuation: Bool = true
    @State var showSeparateRetrievalButton: Bool = false
    @State var forceRetrieval: Bool = false

    @State var autoSummarizeChats: Bool? = nil

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
    }

    var tabsView: some View {
        let composeTabsView = ComposeTabsView(selection: $selectedTab) { tab in
            print("Picked tab \(tab.rawValue)")
        }
            .frame(maxHeight: .infinity)

        return CustomTabView(tabBarView: composeTabsView, tabs: Tab.allCases, selection: selectedTab) {
            VStack(spacing: 0) {
                HStack {
                    InlineTextInput($viewModel.promptInEdit, isFocused: $focusTextInput)
                        .focused($focusTextInput)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                self.focusTextInput = true
                            }
                        }
                        .backgroundStyle(inputBackgroundStyle)
                        .onSubmit {
                            viewModel.requestExtend()
                        }

                    let buttonName: String = {
                        if viewModel.submitting || viewModel.responseInEdit != nil {
                            return "stop.fill"
                        }

                        if !showSeparateRetrievalButton && forceRetrieval {
                            return "arrow.up.doc"
                        }

                        return "arrowshape.up"
                    }()

                    Button(action: {
                        viewModel.requestExtendWithRetrieval()
                    }) {
                        Image(systemName: buttonName)
                            .font(.system(size: 32))
                            .disabled(viewModel.promptInEdit.isEmpty && !allowContinuation)
                            .foregroundStyle((viewModel.promptInEdit.isEmpty && !allowContinuation)
                                             ? Color(.disabledControlTextColor)
                                             : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
            }

            FlowLayout(spacing: 0) {
                GroupBox(content: {
                    TextEditor(text: $overrideSystemPrompt)
                        .frame(width: 360, height: 72)
                        .lineLimit(4...12)
                }, label: {
                    Text("overrideSystemPrompt")
                })

                GroupBox(content: {
                    TextEditor(text: $retrieverOptions)
                        .frame(width: 360, height: 72)
                        .lineLimit(4...12)
                }, label: {
                    Text("retrieverOptions")
                })
            }

            FlowLayout(spacing: 0) {
                GroupBox(content: {
                    TextField("overrideInferenceTemplate", text: $overrideSystemPrompt)
                }, label: {
                    Text("overrideInferenceTemplate")
                })

                GroupBox(content: {
                    TextField("inferenceOptions", text: $inferenceOptions)
                }, label: {
                    Text("inferenceOptions")
                })
            }

            FlowLayout(spacing: 0) {
                GroupBox(content: {
                    VStack(alignment: .leading, spacing: 24) {
                        Toggle(isOn: $allowContinuation, label: { Text("allowContinuation") })
                        Toggle(isOn: $showSeparateRetrievalButton, label: { Text("showSeparateRetrievalButton")})
                        Toggle(isOn: $forceRetrieval, label: { Text("forceRetrieval") })
                    }
                    .padding(24)
                }, label: {
                    Text("Submit Button")
                })

                GroupBox(content: {
                    Text("override generation options")
                    Picker("autoSummarizeChats", selection: $autoSummarizeChats) {
                        Text("allow")
                            .tag(true)

                        Text("deny")
                            .tag(false)

                        Text("server default")
                            .tag(nil as Bool?)
                    }
                }, label: {
                    Text("Generation Options")
                })
            }
        }
        .tabBarPosition(.edge(.leading))
        // TODO: This is very oddly hard-coded. Try layoutPriority on the CustomTabView, next.
        // It's probably something in CustomTabView that's adjusting the height.
        // Or the ComposeTabsView has infinite height.
        .frame(maxHeight: 200)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    if viewModel.sequence.humanDesc != nil {
                        HStack {
                            Text(viewModel.sequence.humanDesc!)
                                .font(.system(size: 36))
                                .padding(.leading, 24)
                                .foregroundColor(.gray)
                                .lineLimit(1)

                            Spacer()
                        }
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

                VStack(spacing: 0) {
                    if viewModel.submitting || viewModel.responseInEdit != nil || viewModel.displayedStatus != nil {
                        // TODO: This doesn't seem like the right UI move, but I don't understand colors yet
                        Divider()

                        HStack {
                            if viewModel.displayedStatus != nil {
                                // TODO: Find a way to persist any changes for at least a few seconds
                                Text(viewModel.displayedStatus ?? "")
                                    .foregroundStyle(Color(.disabledControlTextColor))
                            }

                            Spacer()

                            if viewModel.submitting || viewModel.responseInEdit != nil {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 120)
                            }
                        }
                        .padding(.leading, 24)
                        .padding(.trailing, 24)
                    }

                    tabsView
                } // end of entire lower VStack
                .background(inputBackgroundStyle)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
            }
            .onChange(of: viewModel.sequence.messages) { old, new in
                proxy.scrollTo(viewModel.sequence.messages.last, anchor: .bottom)
            }
            .onChange(of: viewModel.responseInEdit?.content) {
                // TODO: Replace this with a GeometryReader that merely nudges us, if we're already close to the bottom
                proxy.scrollTo(viewModel.responseInEdit, anchor: .bottom)
            }
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
        return SequenceViewTwo(viewModel)
    }
    catch {
        return Text("Failed to construct SequenceViewTwo")
    }
}
