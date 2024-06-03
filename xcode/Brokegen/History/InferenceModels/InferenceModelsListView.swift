import SwiftUI

struct InferenceModelsListView: View {
    @Environment(ProviderService.self) private var providerService

    var body: some View {
        List {
            ForEach(providerService.availableModels) { model in
                OneInferenceModel(model: model)
            }
        }
        .frame(maxWidth: 800)
        .onAppear {
            providerService.fetchAvailableModels()
        }
    }
}
