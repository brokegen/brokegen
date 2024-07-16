import SwiftUI

struct FoundationModelSettingsView: View {
    @ObservedObject var appSettings: AppSettings

    @State private var showDefaultInferenceModelPicker = false
    @State private var showFallbackInferenceModelPicker = false
    @State private var showPreferredAutonamingModelPicker = false
    @State private var showPreferredEmbeddingModelPicker = false

    @ViewBuilder
    func pickerList(_ geometry: GeometryProxy) -> some View {
        if appSettings.stillPopulating {
            ProgressView()
                .progressViewStyle(.linear)
        }

        OFMPicker(
            boxLabel: "Default inference model (for new chats):",
            selectedModelBinding: $appSettings.defaultInferenceModel,
            showModelPicker: $showDefaultInferenceModelPicker,
            geometry: geometry,
            allowClear: true
        )
        .disabled(appSettings.stillPopulating)

        OFMPicker(
            boxLabel: "Fallback inference model (for unavailable providers):",
            selectedModelBinding: $appSettings.fallbackInferenceModel,
            showModelPicker: $showFallbackInferenceModelPicker,
            geometry: geometry,
            allowClear: true
        )
        .disabled(appSettings.stillPopulating)

        OFMPicker(
            boxLabel: "Preferred autonaming model:",
            selectedModelBinding: $appSettings.preferredAutonamingModel,
            showModelPicker: $showPreferredAutonamingModelPicker,
            geometry: geometry,
            allowClear: true
        )
        .disabled(appSettings.stillPopulating)
    }

    var body: some View {
        GeometryReader { geometry in
            // Disable scrolling if everything fits in the view
            ViewThatFits {
                VStack(alignment: .center) {
                    VStack(spacing: 24) {
                        pickerList(geometry)
                            .layoutPriority(0.2)

                        Spacer()
                    }
                    .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)
                }
                .frame(maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .center) {
                        VStack(spacing: 24) {
                            pickerList(geometry)
                                .layoutPriority(0.2)

                            Spacer()
                        }
                        .frame(maxWidth: OneFoundationModelView.preferredMaxWidth)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(BackgroundEffectView().ignoresSafeArea())
    }
}
