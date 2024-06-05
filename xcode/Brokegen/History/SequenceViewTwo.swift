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
                            : darkBackgroundStyle)
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

    init(_ viewModel: ChatSequenceClientModel) {
        self.viewModel = viewModel
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
                        OneMessageView(viewModel.responseInEdit!)
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

                    let composeTabsView = ComposeTabsView(selection: $selectedTab) { tab in
                        print("Picked tab \(tab.rawValue)")
                    }
                        .frame(maxHeight: .infinity)

                    CustomTabView(tabBarView: composeTabsView, tabs: Tab.allCases, selection: selectedTab) {
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

                                Button(action: {
                                    viewModel.requestExtendWithRetrieval()
                                }) {
                                    Image(systemName:
                                            (viewModel.submitting || viewModel.responseInEdit != nil)
                                          ? "stop.fill" : "arrowshape.up")
                                    .font(.system(size: 32))
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 12)
                            }
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
