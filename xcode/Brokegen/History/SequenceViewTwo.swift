import Combine
import CustomTabView
import SwiftUI

let darkBackgroundStyle = Color(.black)

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
        VStack(alignment: .leading) {
            ForEach([Tab.simple, Tab.pro, Tab.proMax], id: \.self) { tab in
                HStack {
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
                            : darkBackgroundStyle)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = tab
                    onTabSelection(tab)
                }
            }

            VStack {
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
            }
        }
        .frame(maxWidth: 80)
    }
}

struct SequenceViewTwo: View {
    @ObservedObject var viewModel: ChatSequenceClientModel
    @FocusState var focusTextInput: Bool
    @State private var selectedTab: Tab = .simple

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ForEach(viewModel.sequence.messages) { message in
                    OneMessageView(message)
                        .padding(24)
                        .padding(.top, 16)
                }

                if viewModel.responseInEdit != nil {
                    OneMessageView(viewModel.responseInEdit!)
                        .padding(24)
                        .padding(.top, 16)
                }
            }
            .layoutPriority(0.5)

            HStack {
                Text("Ollama status: loading model")
                Spacer()
            }
            .foregroundStyle(Color(.disabledControlTextColor))

            let composeTabsView = ComposeTabsView(selection: $selectedTab) { tab in
                print("Picked tab \(tab.rawValue)")
            }
                .frame(maxHeight: .infinity)

            CustomTabView(tabBarView: composeTabsView, tabs: Tab.allCases, selection: selectedTab) {
                VStack {
                    HStack {
                        InlineTextInput($viewModel.promptInEdit, isFocused: $focusTextInput)
                            .padding(.top, 24)
                            .padding(.bottom, 24)
                            .border(.blue)
                            .disabled(viewModel.submitting || viewModel.responseInEdit != nil)
                            .onSubmit {
                                viewModel.requestExtend()
                            }
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    self.focusTextInput = true
                                }
                            }

                        Group {
                            Button(action: viewModel.requestExtendWithRetrieval) {
                                Image(systemName: viewModel.submitting ? "arrowshape.up.fill" : "arrowshape.up")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .disabled(viewModel.submitting || viewModel.responseInEdit != nil)
                            }
                            .buttonStyle(.plain)
                            .help("Submit with Retrieval")
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                    }
                    Spacer()
                }

                HStack {
                    Text("content")
                }
                .tabItem {
                    HStack {
                        Label("  Tab 2", systemImage: "2.circle")
                    }
                    .padding(24)
                }

                VStack {
                    Text("more content")
                }
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }

                VStack {
                    VStack(alignment: .leading) {
                        Text("llama-3-120B")
                            .font(.title)
                            .monospaced()
                            .foregroundColor(.accentColor)
                            .lineLimit(2)
                            .padding(.bottom, 8)

                        Divider()
                        Text("response sec/token: 0.04")
                            .lineLimit(1...)
                            .monospaced()
                            .padding(4)
                    }
                    .padding(12)
                    .listRowSeparator(.hidden)
                    .padding(.bottom, 48)
                    .frame(maxWidth: 800)
                }
            }
            .tabBarPosition(.edge(.leading))
            .layoutPriority(0.2)
        }
        .background(darkBackgroundStyle)
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
