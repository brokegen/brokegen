import SwiftUI

struct InferenceModelSettingsView: View {
    @EnvironmentObject var settings: InferenceModelSettings

    @State private var showDefaultInferenceModelPicker = false
    @State private var showFallbackInferenceModelPicker = false
    @State private var showChatSummaryModelPicker = false
    @State private var showEmbeddingModelPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                GroupBox(label:
                            Text("defaultInferenceModel")
                    .monospaced()
                    .layoutPriority(0.2)
                    .font(.system(size: 36))
                ) {
                    VStack(alignment: .leading, spacing: 36) {
                        if let model = settings.defaultInferenceModel {
                            OneInferenceModelView(
                                model: model,
                                modelAvailable: true,
                                modelSelection: settings.defaultInferenceModelBinding(),
                                enableModelSelection: true)

                            Button(action: {
                                settings.defaultInferenceModelBinding().wrappedValue = nil
                            }) {
                                Text("Clear Model Selection")
                            }
                        }
                        else {
                            Button(action: {
                                showDefaultInferenceModelPicker = true
                            }) {
                                Text("Select Model")
                            }
                        }
                    }
                    .padding(36)
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
                .sheet(isPresented: $showDefaultInferenceModelPicker) {
                    ModelPickerView(modelSelection: settings.defaultInferenceModelBinding())
                        .frame(width: 800, height: 1200, alignment: .top)
                        .animation(.linear(duration: 0.2))
                }
                .layoutPriority(0.2)

                GroupBox(label:
                            Text("fallbackInferenceModel")
                    .monospaced()
                    .layoutPriority(0.2)
                    .font(.system(size: 36))
                ) {
                    VStack(alignment: .leading, spacing: 36) {
                        if let model = settings.fallbackInferenceModel {
                            OneInferenceModelView(
                                model: model,
                                modelAvailable: true,
                                modelSelection: settings.fallbackInferenceModelBinding(),
                                enableModelSelection: true)

                            Button(action: {
                                settings.fallbackInferenceModelBinding().wrappedValue = nil
                            }) {
                                Text("Clear Model Selection")
                            }
                        }
                        else {
                            Button(action: {
                                showFallbackInferenceModelPicker = true
                            }) {
                                Text("Select Model")
                            }
                        }
                    }
                    .padding(36)
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
                .sheet(isPresented: $showFallbackInferenceModelPicker) {
                    ModelPickerView(modelSelection: settings.fallbackInferenceModelBinding())
                        .frame(width: 800, height: 1200, alignment: .top)
                        .animation(.linear(duration: 0.2))
                }
                .layoutPriority(0.2)

                GroupBox(label:
                            Text("chatSummaryModel")
                    .monospaced()
                    .layoutPriority(0.2)
                    .font(.system(size: 36))
                ) {
                    VStack(alignment: .leading, spacing: 36) {
                        if let model = settings.chatSummaryModel {
                            OneInferenceModelView(
                                model: model,
                                modelAvailable: true,
                                modelSelection: settings.chatSummaryModelBinding(),
                                enableModelSelection: true)

                            Button(action: {
                                settings.chatSummaryModelBinding().wrappedValue = nil
                            }) {
                                Text("Clear Model Selection")
                            }
                        }
                        else {
                            Button(action: {
                                showChatSummaryModelPicker = true
                            }) {
                                Text("Select Model")
                            }
                        }
                    }
                    .padding(36)
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
                .sheet(isPresented: $showChatSummaryModelPicker) {
                    ModelPickerView(modelSelection: settings.chatSummaryModelBinding())
                        .frame(width: 800, height: 1200, alignment: .top)
                        .animation(.linear(duration: 0.2))
                }
                .layoutPriority(0.2)

                GroupBox(label:
                            Text("embeddingModel")
                    .monospaced()
                    .layoutPriority(0.2)
                    .font(.system(size: 36))
                ) {
                    VStack(alignment: .leading, spacing: 36) {
                        if let model = settings.embeddingModel {
                            OneInferenceModelView(
                                model: model,
                                modelAvailable: true,
                                modelSelection: settings.embeddingModelBinding(),
                                enableModelSelection: true)

                            Button(action: {
                                settings.embeddingModelBinding().wrappedValue = nil
                            }) {
                                Text("Clear Model Selection")
                            }
                        }
                        else {
                            Button(action: {
                                showEmbeddingModelPicker = true
                            }) {
                                Text("Select Model")
                            }
                        }
                    }
                    .padding(36)
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
                .sheet(isPresented: $showEmbeddingModelPicker) {
                    ModelPickerView(modelSelection: settings.embeddingModelBinding())
                        .frame(width: 800, height: 1200, alignment: .top)
                        .animation(.linear(duration: 0.2))
                }
                .layoutPriority(0.2)

                Spacer()
            }
            .frame(maxWidth: 800)
        }
    }
}
