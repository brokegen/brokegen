import SwiftUI

struct CSCSettingsView: View {
    var settings: CSCSettingsService.SettingsProxy

    func combinedGridRow(
        _ labelText: String,
        globalIsOn: Binding<Bool>,
        localIsOn: Binding<Bool?>,
        trueText: String,
        falseText: String
    ) -> some View {
        GridRow {
            Text(labelText)
            // This should be attached to the widest string in the column, to avoid ellipsising
                .layoutPriority(1.0)

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
        @Bindable var settings = settings

        GroupBox(content: {
            VStack(spacing: 24) {
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
                        Text("Keep chat name pinned to top of window")
                            .layoutPriority(1.0)

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
                        globalIsOn: $settings.defaults.showOFMPicker,
                        localIsOn: $settings.override.showOFMPicker,
                        trueText: "show",
                        falseText: "hide picker"
                    )
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("[global] Font for rendering messages")

                        HStack {
                            Picker("", selection: $settings.messageFontDesign) {
                                ForEach(Font.Design.allCases) { fontDesign in
                                    Text(fontDesign.toString())
                                        .tag(fontDesign)
                                }
                            }
                            .frame(minWidth: 96)

                            Stepper(value: $settings.messageFontSize) {
                                Text(String(format: "%.1f pt", settings.messageFontSize))
                            }
                        }
                    }

                    GridRow {
                        Text("[global] Font for entering prompt text")
                            .layoutPriority(1.0)

                        HStack {
                            Picker("", selection: $settings.textEntryFontDesign) {
                                ForEach(Font.Design.allCases) { fontDesign in
                                    Text(fontDesign.toString())
                                        .tag(fontDesign)
                                }
                            }
                            .frame(minWidth: 96)

                            Stepper(value: $settings.textEntryFontSize) {
                                Text(String(format: "%.1f pt", settings.textEntryFontSize))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }, label: {
            Text("ChatSequence UI Appearance")
                .font(.system(size: 12).lowercaseSmallCaps())
                .padding(.top, 24)
        })
    }

    @ViewBuilder
    var behaviorOptions: some View {
        @Bindable var settings = settings

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
            }
            .padding(24)
        }, label: {
            Text("ChatSequence UI Behaviors")
                .font(.system(size: 12).lowercaseSmallCaps())
                .padding(.top, 24)
        })
    }

    @ViewBuilder
    var performanceOptions: some View {
        @Bindable var settings = settings

        GroupBox(content: {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("Buffer inference output: UI update frequency")
                        .layoutPriority(1.0)

                    HStack {
                        Picker("", selection: $settings.responseBufferFlushFrequencyMsec) {
                            Text("immediately")
                                .tag(0)

                            Text("250 msec")
                                .tag(250)

                            Text("500 msec")
                                .tag(500)

                            Text("1000 msec")
                                .tag(1000)

                            Text("2000 msec")
                                .tag(2000)

                            if !Set([0, 250, 500, 1000, 2000]).contains(settings.responseBufferFlushFrequencyMsec) {
                                Text("custom")
                                    .tag(settings.responseBufferFlushFrequencyMsec)
                            }
                        }
                        .frame(minWidth: 96)

                        Text("/")

                        Stepper(value: $settings.responseBufferFlushFrequencyMsec, step: 50) {
                            Text("\(settings.responseBufferFlushFrequencyMsec)")
                        }

                        Text("msec")

                        Spacer()
                    }
                }

                GridRow {
                    VStack(alignment: .leading) {
                        Text("Scroll to bottom of window on new response text: UI update frequency")
                        Text("(ignored if rendering message as markdown)")
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    HStack {
                        Picker("", selection: $settings.scrollOnNewTextFrequencyMsec) {
                            Text("disabled")
                                .tag(-1)

                            Text("immediately")
                                .tag(0)

                            Text("1000 msec")
                                .tag(1000)

                            Text("2000 msec")
                                .tag(2000)

                            Text("5000 msec")
                                .tag(5000)

                            if !Set([-1, 0, 1000, 2000, 5000]).contains(settings.scrollOnNewTextFrequencyMsec) {
                                Text("custom")
                                    .tag(settings.scrollOnNewTextFrequencyMsec)
                            }
                        }
                        .frame(minWidth: 96)

                        Text("/")

                        Stepper(value: $settings.scrollOnNewTextFrequencyMsec, step: 100) {
                            Text("\(settings.scrollOnNewTextFrequencyMsec)")
                        }

                        Text("msec")

                        Spacer()
                    }
                }

                GridRow {
                    VStack(alignment: .leading) {
                        Text("Animate (fade in) new response text")
                        Text("(ignored if rendering message as markdown)")
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    Picker("", selection: $settings.animateNewResponseText) {
                        Text("animate")
                            .tag(true)

                        Text("don't animate")
                            .tag(false)
                    }
                }
            }
            .padding(24)
        }, label: {
            Text("UI performance tweaks for new inference text (global)")
                .font(.system(size: 12).lowercaseSmallCaps())
                .padding(.top, 24)
        })
    }

    @ViewBuilder
    var inferenceOptions: some View {
        @Bindable var settings = settings

        GroupBox(content: {
            VStack(spacing: 24) {
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

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("[global] Chat autonaming policy")

                        Picker("", selection: $settings.autonamingPolicy) {
                            ForEach(CSInferenceSettings.AutonamingPolicy.allCases) { policy in
                                Text(policy.asUiLabel())
                                    .tag(policy)
                            }
                        }
                        .frame(width: 300)
                        // TODO: Re-enable once we plumb this through on the server
                        .disabled(true)
                    }

                    GridRow {
                        VStack(alignment: .leading) {
                            Text("[global] Batch size for prompt evaluation")
                                .layoutPriority(1.0)
                            Text("Smaller sizes take longer due to prefix-matching. Default: disabled")
                                .foregroundStyle(Color(.disabledControlTextColor))
                        }

                        HStack {
                            let defaultSizes = [64, 128, 256, 512, 1_024, 2_048, 4_096, 8_192, 16_384]
                            let allSizes = Set([0] + defaultSizes)

                            Picker("", selection: $settings.promptEvalBatchSize) {
                                Text("disable batching")
                                    .tag(0)

                                ForEach(defaultSizes, id: \.self) { size in
                                    Text(String(describing: size))
                                        .tag(size)
                                }

                                if !allSizes.contains(settings.promptEvalBatchSize) {
                                    Text("custom")
                                        .tag(settings.promptEvalBatchSize)
                                }
                            }
                            .frame(minWidth: 96)

                            Text("/")

                            let stepSize: Int = { referenceSize in
                                if referenceSize < 32 {
                                    return 4
                                }
                                // Incidentally, the reference/step size increase by 4x each time.
                                else if referenceSize < 128 {
                                    return 8
                                }
                                else if referenceSize < 512 {
                                    return 64
                                }
                                else if referenceSize < 2_048 {
                                    return 256
                                }
                                else if referenceSize < 8_192 {
                                    return 1_024
                                }
                                else if referenceSize < 32_768 {
                                    return 4_096
                                }
                                else {
                                    return 8_192
                                }
                            }(settings.promptEvalBatchSize)

                            Stepper(value: $settings.promptEvalBatchSize, step: stepSize) {
                                Text("\(settings.promptEvalBatchSize)")
                            }
                            .frame(maxWidth: 240)

                            Text("tokens")

                            Spacer()
                        }
                    }

                }
            }
            .padding(24)
        }, label: {
            Text("ChatSequence Inference Options")
                .font(.system(size: 12).lowercaseSmallCaps())
                .padding(.top, 24)
        })
    }

    var body: some View {
        appearanceOptions

        behaviorOptions

        performanceOptions

        inferenceOptions
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 1280)) {
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
                CSCSettingsView(settings: settings)
            }
        }
    }

    return ViewHolder()
}
