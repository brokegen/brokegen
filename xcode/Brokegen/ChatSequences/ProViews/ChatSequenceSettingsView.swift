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
    @ObservedObject var settings: CSCSettingsService.SettingsProxy

    init(
        _ viewModel: OneSequenceViewModel,
        settings: CSCSettingsService.SettingsProxy
    ) {
        self.viewModel = viewModel
        self.settings = settings
    }

    var body: some View {
        GroupBox(content: {
            VStack(spacing: 12) {
                WideToggle(isOn: $settings.defaults.allowContinuation,
                           labelText: "Allow direct continuation (no user input)")
                WideToggle(isOn: $settings.defaults.showSeparateRetrievalButton,
                           labelText: "Show separate retrieval button")
                WideToggle(isOn: $settings.defaults.forceRetrieval,
                           labelText: "Force retrieval-augmented generation on every query")

                WideToggle(isOn: $settings.defaults.allowNewlineSubmit,
                           labelText: "Allow mouseless submit by pressing enter (or if the last pasted character was a newline)")
                WideToggle(isOn: $settings.defaults.stayAwakeDuringInference,
                           labelText: "Assert macOS wakelock during inference requests")
            }
            .toggleStyle(.switch)
            .padding(24)
        }, label: {
            Text("Global Settings")
        })

        GroupBox(content: {
            VStack(spacing: 12) {
                WidePicker(defaultIsOn: settings.defaults.allowContinuation,
                           overrideIsOn: $settings.override.allowContinuation,
                           labelText: "Allow direct continuation", trueText: "allow", falseText: "deny")

                WidePicker(defaultIsOn: settings.defaults.showSeparateRetrievalButton,
                           overrideIsOn: $settings.override.showSeparateRetrievalButton,
                           labelText: "Show separate retrieval button", trueText: "show", falseText: "don't show")

                WidePicker(defaultIsOn: settings.defaults.forceRetrieval,
                           overrideIsOn: $settings.override.forceRetrieval,
                           labelText: "Force retrieval-augmented generation on every query", trueText: "always use retrieval", falseText: "never use retrieval")
                .disabled(settings.override.showSeparateRetrievalButton ?? settings.defaults.showSeparateRetrievalButton)

                Picker(selection: $settings.override.pinChatSequenceDesc, content: {
                    Text("Allow default behavior (pin if a description is set)")
                        .tag(nil as Bool?)

                    Text("pin")
                        .tag(true as Bool?)

                    Text("don't pin")
                        .tag(false as Bool?)
                }, label: {
                    HStack(spacing: 0) {
                        Text("Keep ChatSequence description pinned to top of window")
                            .lineLimit(1...4)

                    }
                })
                .frame(maxWidth: .infinity)

                WidePicker(defaultIsOn: settings.defaults.allowNewlineSubmit,
                           overrideIsOn: $settings.override.allowNewlineSubmit,
                           labelText: "Allow mouseless submit by pressing enter", trueText: "allow", falseText: "don't allow")

                WidePicker(defaultIsOn: settings.defaults.stayAwakeDuringInference,
                           overrideIsOn: $settings.override.stayAwakeDuringInference,
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
            Picker("", selection: $settings.chatAutoNaming) {
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
            Picker("", selection: $settings.chatAutoNaming) {
                Text("inherit global: \(String(describing: settings.chatAutoNaming))")
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
