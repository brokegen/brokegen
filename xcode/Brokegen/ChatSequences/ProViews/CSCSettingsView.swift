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

struct CSCSettingsView: View {
    @ObservedObject var settings: CSCSettingsService.SettingsProxy
    let sequenceDesc: String

    init(
        _ settings: CSCSettingsService.SettingsProxy,
        sequenceDesc: String = "ChatSequence"
    ) {
        self.settings = settings
        self.sequenceDesc = sequenceDesc.isEmpty
        ? ""
        : " for " + sequenceDesc
    }

    @ViewBuilder
    var combinedGrid: some View {
        GroupBox(content: {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Spacer()

                    Text("global")

                    Text("local" + sequenceDesc)
                }

                Divider()

                GridRow {
                    Text("ChatSequence UI Appearance")
                        .font(.system(size: 12).lowercaseSmallCaps())
                        .gridCellColumns(3)
                }

                GridRow {
                    Text("Show ChatMessage headers")
                        .layoutPriority(0.2)

                    Toggle(isOn: $settings.defaults.showMessageHeaders) {
                    }
                    .toggleStyle(.switch)
                    .gridCellUnsizedAxes(.horizontal)

                    Picker(selection: $settings.override.showMessageHeaders, content: {
                        Text(settings.defaults.showMessageHeaders
                             ? "inherit global: show"
                             : "inherit global: hide headers")
                        .tag(nil as Bool?)

                        Text("show")
                            .tag(true as Bool?)

                        Text("hide headers")
                            .tag(false as Bool?)
                    }, label: {})
                    .gridCellUnsizedAxes(.horizontal)
                }

                GridRow {
                    Text("Show InferenceModel override picker")
                        .layoutPriority(0.2)

                    Toggle(isOn: $settings.defaults.showOIMPicker) {
                    }
                    .toggleStyle(.switch)
                    .gridCellUnsizedAxes(.horizontal)

                    Picker(selection: $settings.override.showOIMPicker, content: {
                        Text(settings.defaults.showOIMPicker
                             ? "inherit global: show"
                             : "inherit global: hide picker")
                        .tag(nil as Bool?)

                        Text("show")
                            .tag(true as Bool?)

                        Text("hide picker")
                            .tag(false as Bool?)
                    }, label: {})
                }

                Divider()

                GridRow {
                    Text("ChatSequence Submit Buttons")
                        .font(.system(size: 12).lowercaseSmallCaps())
                        .gridCellColumns(3)
                }

                Divider()

                GridRow {
                    Text("ChatSequence UI Behaviors")
                        .font(.system(size: 12).lowercaseSmallCaps())
                        .gridCellColumns(3)
                }

                GridRow {
                    Text("Scroll to bottom of window on new messages")
                        .layoutPriority(0.2)

                    Toggle(isOn: $settings.defaults.scrollToBottomOnNew) {
                    }
                    .toggleStyle(.switch)
                    .gridCellUnsizedAxes(.horizontal)

                    Picker(selection: $settings.override.scrollToBottomOnNew, content: {
                        Text(settings.defaults.scrollToBottomOnNew
                             ? "inherit global: scroll"
                             : "inherit global: don't scroll")
                        .tag(nil as Bool?)

                        Text("scroll")
                            .tag(true as Bool?)

                        Text("don't scroll")
                            .tag(false as Bool?)
                    }, label: {})
                }
            }
        }, label: {
            Text("ChatSequence settings")
        })
    }

    var body: some View {
        combinedGrid

        GroupBox(content: {
            VStack(spacing: 12) {
                WideToggle(isOn: $settings.defaults.allowContinuation,
                           labelText: "Allow direct continuation (no user input)")
                WideToggle(isOn: $settings.defaults.showSeparateRetrievalButton,
                           labelText: "Show separate retrieval button")
                WideToggle(isOn: $settings.defaults.forceRetrieval,
                           labelText: "Force retrieval-augmented generation on every query")

                WideToggle(isOn: $settings.defaults.showMessageHeaders,
                           labelText: "Show ChatMessage headers in the UI")
                WideToggle(isOn: $settings.defaults.renderAsMarkdown,
                           labelText: "Render message content as markdown")
                WideToggle(isOn: $settings.defaults.scrollToBottomOnNew,
                           labelText: "Scroll to bottom of window on new messages")
                WideToggle(isOn: $settings.defaults.showOIMPicker,
                           labelText: "Show InferenceModel override picker in ChatSequence Views")
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
                        Text("Keep ChatSequence name pinned to top of its View window")
                            .lineLimit(1...4)

                    }
                })
                .frame(maxWidth: .infinity)

                WidePicker(defaultIsOn: settings.defaults.showMessageHeaders,
                           overrideIsOn: $settings.override.showMessageHeaders,
                           labelText: "Show ChatMessage headers in the UI", trueText: "show headers", falseText: "don't show headers")

                WidePicker(defaultIsOn: settings.defaults.renderAsMarkdown,
                           overrideIsOn: $settings.override.renderAsMarkdown,
                           labelText: "Render message content as markdown", trueText: "as markdown", falseText: "as plaintext")

                WidePicker(defaultIsOn: settings.defaults.scrollToBottomOnNew,
                           overrideIsOn: $settings.override.scrollToBottomOnNew,
                           labelText: "Scroll to bottom of window on new messages", trueText: "scroll", falseText: "don't scroll")

                WidePicker(defaultIsOn: settings.defaults.showOIMPicker,
                           overrideIsOn: $settings.override.showOIMPicker,
                           labelText: "Show InferenceModel override picker in ChatSequence Views", trueText: "show", falseText: "don't show")

                WidePicker(defaultIsOn: settings.defaults.stayAwakeDuringInference,
                           overrideIsOn: $settings.override.stayAwakeDuringInference,
                           labelText: "Assert macOS wakelock during inference requests", trueText: "stay awake", falseText: "don't stay awake")
            }
            .pickerStyle(.inline)
            .padding(24)
        }, label: {
            Text("Override Settings\(sequenceDesc)")
        })

        GroupBox(content: {
            Text("ChatSequence auto-naming policy")
            Picker("", selection: $settings.autonamingPolicy) {
                Text("server default")
                    .tag(CSInferenceSettings.AutonamingPolicy.serverDefault)

                Text("disable")
                    .tag(CSInferenceSettings.AutonamingPolicy.disable)

                Text("summarize after inference (asynchronous)")
                    .tag(CSInferenceSettings.AutonamingPolicy.summarizeAfterAsync)

                Text("summarize before inference")
                    .tag(CSInferenceSettings.AutonamingPolicy.summarizeBefore)
            }
            .pickerStyle(.inline)

            HStack {
                WideToggle(isOn:
                            Binding(
                                get: { $settings.defaults.responseBufferMaxSize.wrappedValue > 0 },
                                set: { newValue in
                                    print("[TRACE] Trying to set responseBufferMaxSize to \(newValue)")
                                    if newValue {
                                        settings.defaults.responseBufferMaxSize = 48
                                    }
                                    else {
                                        settings.defaults.responseBufferMaxSize = 0
                                    }}),
                           labelText: "Buffer inference results for more responsive UI")

                Stepper(value: $settings.defaults.responseBufferMaxSize) {
                    Text("\(settings.defaults.responseBufferMaxSize)")
                }

                Picker("", selection: $settings.defaults.responseBufferMaxSize) {
                    Text("disabled")
                        .tag(0)

                    Text("12")
                        .tag(12)

                    Text("24")
                        .tag(24)

                    Text("48")
                        .tag(48)

                    Text("96")
                        .tag(96)
                }
            } // HStack
        }, label: {
            Text("ChatSequence Generation Options")
        })
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct ViewHolder: View {
        @State var settings: CSCSettingsService.SettingsProxy

        init() {
            settings = CSCSettingsService.SettingsProxy(
                defaults: PersistentDefaultCSUISettings(),
                override: OverrideCSUISettings(),
                inference: CSInferenceSettings()
            )
        }

        var body: some View {
            ScrollView {
                CSCSettingsView(settings)
            }
        }
    }

    return ViewHolder()
}
