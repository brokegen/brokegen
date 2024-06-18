import SwiftUI

struct InferenceModelSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    
    @State private var showDefaultInferenceModelPicker = false
    @State private var showFallbackInferenceModelPicker = false
    @State private var showChatSummaryModelPicker = false
    @State private var showPreferredEmbeddingModelPicker = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    if appSettings.stillPopulating {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    OIMPicker(
                        boxLabel: "defaultInferenceModel",
                        selectedModelBinding: $appSettings.defaultInferenceModel,
                        showModelPicker: $showDefaultInferenceModelPicker,
                        geometry: geometry,
                        allowClear: true
                    )

                    OIMPicker(
                        boxLabel: "fallbackInferenceModel",
                        selectedModelBinding: $appSettings.fallbackInferenceModel,
                        showModelPicker: $showFallbackInferenceModelPicker,
                        geometry: geometry,
                        allowClear: true
                    )

                    OIMPicker(
                        boxLabel: "chatSummaryModel",
                        selectedModelBinding: $appSettings.chatSummaryModel,
                        showModelPicker: $showChatSummaryModelPicker,
                        geometry: geometry,
                        allowClear: true
                    )

                    OIMPicker(
                        boxLabel: "preferredEmbeddingModel",
                        selectedModelBinding: $appSettings.preferredEmbeddingModel,
                        showModelPicker: $showPreferredEmbeddingModelPicker,
                        geometry: geometry,
                        allowClear: true
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
