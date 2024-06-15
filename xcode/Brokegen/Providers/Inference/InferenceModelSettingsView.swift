import SwiftUI

struct InferenceModelSettingsView: View {
    @Bindable var settings: InferenceModelSettings

    @State private var showDefaultInferenceModelPicker = false
    @State private var showFallbackInferenceModelPicker = false
    @State private var showChatSummaryModelPicker = false
    @State private var showPreferredEmbeddingModelPicker = false

    init(_ settings: InferenceModelSettings) {
        self.settings = settings
    }

    func boxMaker(
        _ boxLabel: String,
        selectedModelBinding: Binding<InferenceModel?>,
        showModelPicker: Binding<Bool>,
        geometry: GeometryProxy
    ) -> some View {
        GroupBox(label:
                    Text(boxLabel)
            .monospaced()
            .layoutPriority(0.2)
            .font(.system(size: 36))
        ) {
            VStack(alignment: .leading, spacing: 36) {
                if let model = selectedModelBinding.wrappedValue {
                    OneInferenceModelView(
                        model: model,
                        modelAvailable: true,
                        modelSelection: selectedModelBinding,
                        enableModelSelection: true)

                    HStack(alignment: .bottom, spacing: 0) {
                        Button(action: {
                            showModelPicker.wrappedValue = true
                        }) {
                            Text("Reselect Model")
                                .font(.system(size: 24))
                                .padding(12)
                        }

                        Spacer()
                            .frame(minWidth: 0)

                        Button(action: {
                            selectedModelBinding.wrappedValue = nil
                        }) {
                            Text("Clear Model Selection")
                                .font(.system(size: 24))
                                .padding(12)
                        }
                    }
                }
                else {
                    Button(action: {
                        showModelPicker.wrappedValue = true
                    }) {
                        Text("Select Model")
                            .font(.system(size: 24))
                            .padding(12)
                    }
                }
            }
            .padding(36)
            .frame(minHeight: 144)

            Spacer()
                .frame(maxWidth: .infinity, maxHeight: 0)
        }
        .sheet(isPresented: showModelPicker) {
            ModelPickerView(modelSelection: selectedModelBinding)
                .frame(
                    width: max(840 + 2 * 24, geometry.size.width * 0.8),
                    height: max(840 + 2 * 24, geometry.size.height * 0.8),
                    alignment: .top)
                .animation(.linear(duration: 0.2))
        }
        .frame(minHeight: 160)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    if settings.stillPopulating {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    boxMaker("defaultInferenceModel",
                             selectedModelBinding: $settings.defaultInferenceModel,
                             showModelPicker: $showDefaultInferenceModelPicker,
                             geometry: geometry
                    )

                    boxMaker("fallbackInferenceModel",
                             selectedModelBinding: $settings.fallbackInferenceModel,
                             showModelPicker: $showFallbackInferenceModelPicker,
                             geometry: geometry
                    )


                    boxMaker("chatSummaryModel",
                             selectedModelBinding: $settings.chatSummaryModel,
                             showModelPicker: $showChatSummaryModelPicker,
                             geometry: geometry
                    )


                    boxMaker("preferredEmbeddingModel",
                             selectedModelBinding: $settings.preferredEmbeddingModel,
                             showModelPicker: $showPreferredEmbeddingModelPicker,
                             geometry: geometry
                    )

                    Spacer()
                        .frame(minHeight: 0)
                }
                .frame(maxWidth: 840 + 2 * 24)
            }
            .frame(maxWidth: .infinity)
            .background(BackgroundEffectView().ignoresSafeArea())
        }
    }
}
