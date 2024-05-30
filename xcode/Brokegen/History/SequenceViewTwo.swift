import Combine
import CustomTabView
import SwiftUI

enum Tab: String, Hashable, CaseIterable {
    case hidden, simple, configurable, advanced
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
            Spacer()

            ForEach(Tab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: selection == tab ? "circle.fill" : "circle")
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = tab
                        onTabSelection(tab)
                    }

                Spacer()
            }
        }
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
        List {
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

        let composeTabsView = ComposeTabsView(selection: $selectedTab) { tab in
            print("Picked tab \(tab.rawValue)")
        }
            .frame(maxHeight: .infinity)

        CustomTabView(tabBarView: composeTabsView, tabs: Tab.allCases, selection: selectedTab) {
            Rectangle()
                .fill(Color.clear)

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
                    //                Button(action: viewModel.stopSubmitAndReceive) {
                    //                    let icon: String = {
                    //                        if viewModel.submitting || viewModel.responseInEdit != nil {
                    //                            return "stop.fill"
                    //                        }
                    //                        else {
                    //                            return "stop"
                    //                        }
                    //                    }()
                    //                    Image(systemName: icon)
                    //                        .resizable()
                    //                        .frame(width: 32, height: 32)
                    //                        .disabled(!viewModel.submitting && viewModel.responseInEdit == nil)
                    //                }
                    //                .buttonStyle(.plain)
                    //                .help("Stop submitting or receiving")

                    Button(action: viewModel.requestExtendWithRetrieval) {
                        Image(systemName: viewModel.submitting ? "arrowshape.up.fill" : "arrowshape.up")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(viewModel.submitting || viewModel.responseInEdit != nil)
                    }
                    .buttonStyle(.plain)
                    .help("Submit with Retrieval-Augmented Generation")

                    //                Button(action: viewModel.requestExtend) {
                    //                    Image(systemName: viewModel.submitting ? "arrow.up.circle.fill" : "arrow.up.circle")
                    //                        .resizable()
                    //                        .frame(width: 32, height: 32)
                    //                        .disabled(viewModel.submitting || viewModel.responseInEdit != nil)
                    //                }
                    //                .buttonStyle(.plain)
                    //                .help("Submit")
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
                .padding(.leading, 12)
                .padding(.trailing, -12)
            }
            .tabItem {
                Text("normal")
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
        }
        .tabBarPosition(selectedTab == .hidden ? .floating(.leading) : .edge(.leading))
//        .frame(width: 800, height: 200)
        .padding(.leading, 24)
        .padding(.trailing, 24)
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 400)) {
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
        let viewModel = ChatSequenceClientModel(sequence, chatService: chatService)
        return SequenceViewTwo(viewModel)
    }
    catch {
        return Text("Failed to construct SequenceViewTwo")
    }
}
