import SwiftUI

struct ChatSequenceSettingsView: View {
    var globalSettings: Binding<GlobalChatSequenceClientSettings>
    var settings: Binding<ChatSequenceClientSettings>

    init(
        globalSettings: Binding<GlobalChatSequenceClientSettings>,
        settings: Binding<ChatSequenceClientSettings>
    ) {
        self.globalSettings = globalSettings
        self.settings = settings
    }

    @ViewBuilder var boxMaker: some View {
        GroupBox(content: {
            VFlowLayout(spacing: 24) {
                Toggle(isOn: globalSettings.allowContinuation, label: { Text("allowContinuation") })
                Toggle(isOn: globalSettings.showSeparateRetrievalButton, label: { Text("showSeparateRetrievalButton") })
                Toggle(isOn: globalSettings.forceRetrieval, label: { Text("forceRetrieval") })
                    .disabled(globalSettings.forceRetrieval.wrappedValue)

                Spacer()

                Toggle(isOn: globalSettings.allowNewlineSubmit, label: { Text("allowNewlineSubmit") })
                Toggle(isOn: globalSettings.stayAwakeDuringInference, label: { Text("stayAwakeDuringInference") })
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 768)
            .padding(24)
        }, label: {
            Text("Global Settings")
        })

        GroupBox(content: {
            VFlowLayout(spacing: 24) {
                Picker("allowContinuation", selection: settings.allowContinuation) {
                    Text("inherit global: \(String(describing: globalSettings.allowContinuation.wrappedValue))")
                        .tag(nil as Bool?)

                    Text("allow")
                        .tag(true as Bool?)

                    Text("deny")
                        .tag(false as Bool?)
                }
                .pickerStyle(.segmented)

                Picker("showSeparateRetrievalButton", selection: settings.showSeparateRetrievalButton) {
                    Text("inherit global: \(String(describing: globalSettings.showSeparateRetrievalButton.wrappedValue))")
                        .tag(nil as Bool?)

                    Text("show")
                        .tag(true as Bool?)

                    Text("don't show")
                        .tag(false as Bool?)
                }
                .pickerStyle(.inline)

                Picker("forceRetrieval", selection: settings.forceRetrieval) {
                    Text("inherit global: \(String(describing: globalSettings.forceRetrieval.wrappedValue))")
                        .tag(nil as Bool?)

                    Text("always use retrieval")
                        .tag(true as Bool?)

                    Text("never use retrieval")
                        .tag(false as Bool?)
                }
                .pickerStyle(.palette)
                .disabled(settings.showSeparateRetrievalButton.wrappedValue ?? globalSettings.showSeparateRetrievalButton.wrappedValue)

                Picker("allowNewlineSubmit", selection: settings.allowNewlineSubmit) {
                    Text("inherit global: \(String(describing: globalSettings.allowNewlineSubmit.wrappedValue))")
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
            Picker("", selection: globalSettings.chatAutoNaming) {
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
            Picker("", selection: settings.chatAutoNaming) {
                Text("inherit global: \(String(describing: globalSettings.chatAutoNaming.wrappedValue))")
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

    var body: some View {
        ViewThatFits {
            VFlowLayout {
                boxMaker
            }

            ScrollView {
                VFlowLayout(spacing: 0) {
                    boxMaker
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

#Preview(traits: .fixedLayout(width: 1600, height: 360)) {
    @State var globalSequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()
    @State var sequenceSettings: ChatSequenceClientSettings = ChatSequenceClientSettings()

    return ChatSequenceSettingsView(globalSettings: $globalSequenceSettings, settings: $sequenceSettings)
}

#Preview {
    @State var globalSequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()
    @State var sequenceSettings: ChatSequenceClientSettings = ChatSequenceClientSettings()

    return ChatSequenceSettingsView(globalSettings: $globalSequenceSettings, settings: $sequenceSettings)
}
