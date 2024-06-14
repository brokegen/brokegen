import SwiftUI

struct WideToggle: View {
    let isOn: Binding<Bool>
    let labelText: String

    var body: some View {
        Toggle(isOn: isOn, label: {
            HStack(spacing: 0) {
                Text(labelText)
                    .lineLimit(1...4)
                    .layoutPriority(0.2)

                Spacer()
            }
        })
        .frame(maxWidth: .infinity)
    }
}

struct WidePicker: View {
    var defaultIsOn: Bool
    var overrideIsOn: Binding<Bool?>
    let labelText: String
    let trueText: String
    let falseText: String

    var body: some View {
        Picker(selection: overrideIsOn, content: {
            Text("inherit global: \(defaultIsOn ? trueText : falseText)")
                .tag(nil as Bool?)

            Text(trueText)
                .tag(true as Bool?)

            Text(falseText)
                .tag(false as Bool?)
        }, label: {
            HStack(spacing: 0) {
                Text(labelText)
                    .lineLimit(1...4)

            }
        })
        .frame(maxWidth: .infinity)
    }
}

struct ChatSequenceSettingsView: View {
    @ObservedObject var viewModel: OneSequenceViewModel
    @ObservedObject var uiSettings: CombinedCSUISettings

    init(
        _ viewModel: OneSequenceViewModel
    ) {
        self.viewModel = viewModel
        self.uiSettings = viewModel.uiSettings
    }

    var body: some View {
        GroupBox(content: {
            VStack(spacing: 12) {
                WideToggle(isOn: $uiSettings.defaults.allowContinuation,
                           labelText: "Allow direct continuation (no user input)")
                WideToggle(isOn: $uiSettings.defaults.showSeparateRetrievalButton,
                           labelText: "Show separate retrieval button")
                WideToggle(isOn: $uiSettings.defaults.forceRetrieval,
                           labelText: "Force retrieval-augmented generation on every query")

//                WidePicker(defaultIsOn: uiSettings.defaults.pinSequenceTitle,
//                           overrideIsOn: $uiSettings.override.pinSequenceTitle,
//                           labelText: "Pin ChatSequence titles to top of window", trueText: "pin", falseText: "don't pin")
                WideToggle(isOn: $uiSettings.defaults.allowNewlineSubmit,
                           labelText: "Allow mouseless submit by pressing enter (or if the last pasted character was a newline)")
                WideToggle(isOn: $uiSettings.defaults.stayAwakeDuringInference,
                           labelText: "Assert macOS wakelock during inference requests")
            }
            .toggleStyle(.switch)
            .padding(24)
        }, label: {
            Text("Global Settings")
        })

        GroupBox(content: {
            VStack(spacing: 12) {
                WidePicker(defaultIsOn: uiSettings.defaults.allowContinuation,
                           overrideIsOn: $uiSettings.override.allowContinuation,
                           labelText: "Allow direct continuation", trueText: "allow", falseText: "deny")

                WidePicker(defaultIsOn: uiSettings.defaults.showSeparateRetrievalButton,
                           overrideIsOn: $uiSettings.override.showSeparateRetrievalButton,
                           labelText: "Show separate retrieval button", trueText: "show", falseText: "don't show")

                WidePicker(defaultIsOn: uiSettings.defaults.forceRetrieval,
                           overrideIsOn: $uiSettings.override.forceRetrieval,
                           labelText: "Force retrieval-augmented generation on every query", trueText: "always use retrieval", falseText: "never use retrieval")
                .disabled(uiSettings.override.showSeparateRetrievalButton ?? uiSettings.defaults.showSeparateRetrievalButton)


                WidePicker(defaultIsOn: uiSettings.defaults.allowNewlineSubmit,
                           overrideIsOn: $uiSettings.override.allowNewlineSubmit,
                           labelText: "Allow mouseless submit by pressing enter", trueText: "allow", falseText: "don't allow")

                WidePicker(defaultIsOn: uiSettings.defaults.stayAwakeDuringInference,
                           overrideIsOn: $uiSettings.override.stayAwakeDuringInference,
                           labelText: "Assert macOS wakelock during inference requests", trueText: "stay awake", falseText: "don't stay awake")
            }
            .pickerStyle(.inline)
            .padding(24)
        }, label: {
            let chatLabel: String = {
                if viewModel.sequence.serverId != nil {
                    " for ChatSequence#\(viewModel.sequence.serverId!)"
                }
                else {
                    ""
                }
            }()

            Text("Override Settings\(chatLabel)")
        })

        GroupBox(content: {
            Text("globalSettings.chatAutoNaming")
            Picker("", selection: $viewModel.globalSequenceSettings.chatAutoNaming) {
                Text("server default")
                    .tag(ChatAutoNaming.serverDefault)

                Text("disable")
                    .tag(ChatAutoNaming.disable)

                Text("summarize after inference (asynchronous)")
                    .tag(ChatAutoNaming.summarizeAfterAsync)

                Text("summarize before inference")
                    .tag(ChatAutoNaming.summarizeBefore)
            }
            .pickerStyle(.inline)

            Text("chatAutoNaming")
            Picker("", selection: $viewModel.sequenceSettings.chatAutoNaming) {
                Text("inherit global: \(String(describing: viewModel.globalSequenceSettings.chatAutoNaming))")
                    .tag(nil as ChatAutoNaming?)

                Text("server default")
                    .tag(ChatAutoNaming.serverDefault)

                Text("disable")
                    .tag(ChatAutoNaming.disable)

                Text("summarize after inference (asynchronous)")
                    .tag(ChatAutoNaming.summarizeAfterAsync)

                Text("summarize before inference")
                    .tag(ChatAutoNaming.summarizeBefore)
            }
            .pickerStyle(.inline)
        }, label: {
            Text("ChatSequence Generation Options")
        })
    }
}

//#Preview(traits: .fixedLayout(width: 1600, height: 360)) {
//    @State var globalSequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()
//    @State var sequenceSettings: ChatSequenceClientSettings = ChatSequenceClientSettings()
//
//    var viewModel = OneSequenceViewModel()
//
//    return ChatSequenceSettingsView(globalSettings: $globalSequenceSettings, settings: $sequenceSettings)
//}
//
//#Preview {
//    @State var globalSequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()
//    @State var sequenceSettings: ChatSequenceClientSettings = ChatSequenceClientSettings()
//
//    return ChatSequenceSettingsView(globalSettings: $globalSequenceSettings, settings: $sequenceSettings)
//}
