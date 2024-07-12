import SwiftUI

struct CSCSettingsView: View {
    @ObservedObject var settings: CSCSettingsService.SettingsProxy
    @State var generationWidth: CGFloat = 0

    init(
        _ settings: CSCSettingsService.SettingsProxy
    ) {
        self.settings = settings
    }

    func combinedGridRow(
        _ labelText: String,
        globalIsOn: Binding<Bool>,
        localIsOn: Binding<Bool?>,
        trueText: String,
        falseText: String
    ) -> some View {
        GridRow {
            Text(labelText)
                .layoutPriority(0.2)

            Toggle(isOn: globalIsOn) {}
                .toggleStyle(.switch)

            Picker(selection: localIsOn, content: {
                Text(globalIsOn.wrappedValue
                     ? "inherit global: " + trueText
                     : "inherit global: " + falseText)
                .tag(nil as Bool?)

                Text(trueText)
                    .tag(true as Bool?)

                Text(falseText)
                    .tag(false as Bool?)
            }, label: {})
        }
    }

    @ViewBuilder
    var appearanceOptions: some View {
        GroupBox(content: {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Spacer()

                    Text("global")
                        .gridColumnAlignment(.trailing)

                    Text("this sequence")
                        .gridColumnAlignment(.center)
                        .frame(minWidth: 288)
                }
                Divider()

                GridRow {
                    Text("Pin chat name to the top of the window")
                        .layoutPriority(0.2)

                    Text("")

                    Picker(selection: $settings.override.pinChatSequenceDesc, content: {
                        Text("default behavior: pin if a name exists")
                            .tag(nil as Bool?)

                        Text("always pin")
                            .tag(true as Bool?)

                        Text("don't pin")
                            .tag(false as Bool?)
                    }, label: {})
                }

                combinedGridRow(
                    "Show message headers",
                    globalIsOn: $settings.defaults.showMessageHeaders,
                    localIsOn: $settings.override.showMessageHeaders,
                    trueText: "show",
                    falseText: "hide headers"
                )

                combinedGridRow(
                    "Render message content as markdown",
                    globalIsOn: $settings.defaults.renderAsMarkdown,
                    localIsOn: $settings.override.renderAsMarkdown,
                    trueText: "as markdown",
                    falseText: "as plaintext"
                )

                combinedGridRow(
                    "Show inference model override picker",
                    globalIsOn: $settings.defaults.showOIMPicker,
                    localIsOn: $settings.override.showOIMPicker,
                    trueText: "show",
                    falseText: "hide picker"
                )
            }
            .padding(24)
        }, label: {
            Text("ChatSequence UI Appearance")
                .font(.system(size: 12).lowercaseSmallCaps())
                .gridCellColumns(3)
                .padding(.top, 24)
        })
    }

    @ViewBuilder
    var behaviorOptions: some View {
        GroupBox(content: {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Spacer()

                    Text("global")
                        .gridColumnAlignment(.trailing)

                    Text("this sequence")
                        .gridColumnAlignment(.center)
                        .frame(minWidth: 240)
                }
                Divider()

                combinedGridRow(
                    "Allow direct continuation (model talks to itself)",
                    globalIsOn: $settings.defaults.allowContinuation,
                    localIsOn: $settings.override.allowContinuation,
                    trueText: "allow",
                    falseText: "require user prompt"
                )

                combinedGridRow(
                    "Show separate retrieval button",
                    globalIsOn: $settings.defaults.showSeparateRetrievalButton,
                    localIsOn: $settings.override.showSeparateRetrievalButton,
                    trueText: "show",
                    falseText: "combine buttons"
                )

                GridRow {
                    Text("Force retrieval-augmented generation on every query")
                        .layoutPriority(0.2)

                    Toggle(isOn: $settings.defaults.forceRetrieval) {}
                        .toggleStyle(.switch)
                        .disabled(settings.showSeparateRetrievalButton)

                    if settings.showSeparateRetrievalButton {
                        Picker(selection: .constant(false), content: {
                            Text("[separate retrieval button]")
                                .tag(false)
                        }, label: {})
                        .disabled(true)
                    }
                    else {
                        Picker(selection: $settings.override.forceRetrieval, content: {
                            Text(settings.defaults.forceRetrieval
                                 ? "inherit global: always use RAG"
                                 : "inherit global: disable")
                            .tag(nil as Bool?)

                            Text("always use RAG")
                                .tag(true as Bool?)

                            Text("disable")
                                .tag(false as Bool?)
                        }, label: {})
                    }
                }

                Divider()

                combinedGridRow(
                    "Scroll to bottom of window on new messages",
                    globalIsOn: $settings.defaults.scrollToBottomOnNew,
                    localIsOn: $settings.override.scrollToBottomOnNew,
                    trueText: "scroll",
                    falseText: "don't scroll"
                )

                GridRow {
                    Text("Buffer inference results for more responsive UI")
                        .layoutPriority(0.2)

                    Text("")

                    HStack {
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

                            Text("custom")
                                .tag(settings.defaults.responseBufferMaxSize)
                        }
                        .frame(minWidth: 96)

                        Text("(customize:")

                        Stepper(value: $settings.defaults.responseBufferMaxSize) {
                            Text("\(settings.defaults.responseBufferMaxSize)")
                        }

                        Text("chars)")

                        Spacer()
                    }
                    .padding(.leading, -8)
                }

                GridRow {
                    Text("Animate (fade in) new response text")
                        .layoutPriority(0.2)

                    Text("")

                    Picker("", selection: $settings.override.animateNewResponseText) {
                        Text("animate (.snappy)")
                            .tag(true)

                        Text("disable")
                            .tag(false)
                    }
                    .padding(.leading, -8)
                }
            }
            .padding(24)
        }, label: {
            Text("ChatSequence UI Behaviors")
                .font(.system(size: 12).lowercaseSmallCaps())
                .gridCellColumns(3)
                .padding(.top, 24)
        })
    }

    @ViewBuilder
    var generationOptions: some View {
        GroupBox(content: {
            VStack(spacing: 24) {
                Picker("Chat autonaming policy (global)", selection: $settings.autonamingPolicy) {
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
                // TODO: Re-enable once we plumb this through on the server
                .disabled(true)

                Divider()
                    .frame(maxWidth: generationWidth)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Spacer()

                        Text("global")
                            .gridColumnAlignment(.trailing)

                        Text("this sequence")
                            .frame(minWidth: 240)
                    }
                    Divider()

                    combinedGridRow(
                        "Assert macOS wakelock during inference requests",
                        globalIsOn: $settings.defaults.stayAwakeDuringInference,
                        localIsOn: $settings.override.stayAwakeDuringInference,
                        trueText: "stay awake",
                        falseText: "don't stay awake"
                    )
                }
            }
            .overlay {
                // Read the target width of this entire block,
                // so we can apply it to Divider() which is otherwise greedy
                GeometryReader { geometry in
                    Spacer()
                        .onAppear {
                            generationWidth = geometry.size.width
                        }
                }
            }
            .padding(24)
        }, label: {
            Text("ChatSequence Inference Options")
                .font(.system(size: 12).lowercaseSmallCaps())
                .gridCellColumns(3)
                .padding(.top, 24)
        })
    }

    var body: some View {
        appearanceOptions

        behaviorOptions

        generationOptions
    }
}

#Preview(traits: .fixedLayout(width: 1280, height: 1280)) {
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
