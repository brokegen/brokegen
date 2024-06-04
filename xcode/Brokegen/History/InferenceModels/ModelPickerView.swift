import SwiftUI

struct ModelPickerView: View {
    @Environment(ProviderService.self) private var providerService
    @Environment(\.dismiss) var dismiss

    private var modelSelection: Binding<InferenceModel?>
    private var enableModelSelection: Bool

    init(modelSelection: Binding<InferenceModel?>? = nil) {
        if modelSelection != nil {
            self.modelSelection = modelSelection!
            self.enableModelSelection = true
        }
        else {
            self.modelSelection = Binding(
                get: { return nil },
                set: { newModel in
                }
            )
            self.enableModelSelection = false
        }
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            // TODO: This doesn't scroll.
            // Also, ViewThatFits will just pop it out of existence, willy-nilly.
//            FlowLayout() {
//                ForEach(providerService.availableModels) { model in
//                    OneInferenceModel()
//                }
//            }

            List {
                ForEach(providerService.allModels) { model in
                    OneInferenceModel(
                        model: model,
                        modelAvailable: providerService.availableModels.contains {
                            $0.serverId == model.serverId
                        },
                        modelSelection: modelSelection,
                        enableModelSelection: enableModelSelection
                    )
                    .expandContent(true)
                    .padding(36)
                }
            }
        }
        .onAppear {
            providerService.fetchAvailableModels()
        }
        .onChange(of: modelSelection.wrappedValue?.serverId) {
            dismiss.callAsFunction()
        }
    }
}
