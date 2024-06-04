import SwiftUI

struct ModelPickerView: View {
    @Environment(ProviderService.self) private var providerService

    var body: some View {
        ViewThatFits(in: .vertical) {
            List {
                ForEach(providerService.allModels) { model in
                    OneInferenceModel(
                        model: model,
                        // Duplicate predicate, for now
                        modelAvailable:
                            model.humanId.contains("instruct") || model.stats?.count ?? 0 > 1
                    )
                    .padding(36)
                }
            }

            // TODO: This will never show. And it doesn't scroll.
            FlowLayout(spacing: 72) {
                ForEach(providerService.availableModels) { model in
                    OneInferenceModel(
                        model: model,
                        modelAvailable: true
                    )
                }
            }
        }
        .onAppear {
            providerService.fetchAvailableModels()
        }
    }
}
