import SwiftUI

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
            VFlowLayout(spacing: 24) {
                Toggle(isOn: $uiSettings.defaults.allowContinuation, label: {
                    Text("allowContinuation")
                        .layoutPriority(0.2)

                    Spacer()
                })
                Toggle(isOn: $uiSettings.defaults.showSeparateRetrievalButton, label: { Text("showSeparateRetrievalButton") })
                Toggle(isOn: $uiSettings.defaults.forceRetrieval, label: { Text("forceRetrieval") })
                    .disabled(uiSettings.defaults.forceRetrieval)

                Spacer()

                Toggle(isOn: $uiSettings.defaults.allowNewlineSubmit, label: { Text("allowNewlineSubmit") })
                Toggle(isOn: $uiSettings.defaults.stayAwakeDuringInference, label: { Text("stayAwakeDuringInference") })
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 768)
            .padding(24)
        }, label: {
            Text("Global Settings")
        })

        GroupBox(content: {
            VFlowLayout(spacing: 24) {
                Picker("allowContinuation", selection: $uiSettings.override.allowContinuation) {
                    Text("inherit global: \(String(describing: uiSettings.defaults.allowContinuation))")
                        .tag(nil as Bool?)

                    Text("allow")
                        .tag(true as Bool?)

                    Text("deny")
                        .tag(false as Bool?)
                }
                .pickerStyle(.segmented)

                Picker("showSeparateRetrievalButton", selection: $uiSettings.override.showSeparateRetrievalButton) {
                    Text("inherit global: \(String(describing: uiSettings.defaults.showSeparateRetrievalButton))")
                        .tag(nil as Bool?)

                    Text("show")
                        .tag(true as Bool?)

                    Text("don't show")
                        .tag(false as Bool?)
                }
                .pickerStyle(.inline)

                Picker("forceRetrieval", selection: $uiSettings.override.forceRetrieval) {
                    Text("inherit global: \(String(describing: uiSettings.defaults.forceRetrieval))")
                        .tag(nil as Bool?)

                    Text("always use retrieval")
                        .tag(true as Bool?)

                    Text("never use retrieval")
                        .tag(false as Bool?)
                }
                .pickerStyle(.palette)
                .disabled(uiSettings.override.showSeparateRetrievalButton ?? uiSettings.defaults.showSeparateRetrievalButton)

                Picker("allowNewlineSubmit", selection: $uiSettings.override.allowNewlineSubmit) {
                    Text("inherit global: \(String(describing: uiSettings.defaults.allowNewlineSubmit))")
                        .tag(nil as Bool?)

                    Text("show")
                        .tag(true as Bool?)

                    Text("don't show")
                        .tag(false as Bool?)
                }
                .pickerStyle(.radioGroup)
            }
            .frame(maxWidth: 768)
            .padding(24)
        }, label: {
            Text("ChatSequence Settings")
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
//
//#Preview(traits: .fixedLayout(width: 1600, height: 360)) {
//    @State var globalSequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()
//    @State var sequenceSettings: ChatSequenceClientSettings = ChatSequenceClientSettings()
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
