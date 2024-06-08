import SwiftUI

struct ModelPickerView: View {
    @Environment(ProviderService.self) private var providerService
    @Environment(\.dismiss) var dismiss

    private var modelSelection: Binding<InferenceModel?>
    private var enableModelSelection: Bool
    private var hideDismissButton: Bool
    @State private var isDismissButtonHovered: Bool = false

    init(
        modelSelection: Binding<InferenceModel?>? = nil
    ) {
        if modelSelection != nil {
            self.modelSelection = modelSelection!
            self.enableModelSelection = true
            self.hideDismissButton = false
        }
        else {
            self.modelSelection = Binding(
                get: { return nil },
                set: { newModel in
                }
            )
            self.enableModelSelection = false
            self.hideDismissButton = true
        }
    }

    var body: some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .top)) {
            ViewThatFits(in: .horizontal) {
                // TODO: ViewThatFits will just pop in and out of existence, willy-nilly.
                // Which makes it very hard to track items in a particular spot,
                // especially since sorting is virtually random.
                ScrollView {
                    VFlowLayout(spacing: 24) {
                        ForEach(providerService.allModels) { model in
                            OneInferenceModelView(
                                model: model,
                                modelAvailable: providerService.availableModels.contains {
                                    $0.serverId == model.serverId
                                },
                                modelSelection: modelSelection,
                                enableModelSelection: enableModelSelection
                            )
                        }
                    }
                }
                .padding(24)

                List {
                    ForEach(providerService.allModels) { model in
                        OneInferenceModelView(
                            model: model,
                            modelAvailable: providerService.availableModels.contains {
                                $0.serverId == model.serverId
                            },
                            modelSelection: modelSelection,
                            enableModelSelection: enableModelSelection
                        )
                        .expandContent(true)
                        .padding(24)
                        .padding(.bottom, 0)
                    }

                    Text("End of loaded InferenceModels")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)
                }
            }

            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 32))
                    .padding(12)
                    .background(
                        Rectangle()
                            .fill(isDismissButtonHovered ? Color(.selectedControlColor) : Color.clear)
                    )
            }
            .onHover { isHovered in
                isDismissButtonHovered = isHovered
            }
            .buttonStyle(.plain)
            .padding(24)
        }
        .onAppear {
            Task {
                await providerService.fetchAvailableModels()
            }
        }
        .onChange(of: modelSelection.wrappedValue?.serverId) {
            if modelSelection.wrappedValue != nil {
                dismiss.callAsFunction()
            }
        }
    }
}

fileprivate func makeFakeModel() -> InferenceModel {
    return InferenceModel(
        id: UUID(),
        serverId: 1000,
        humanId: "test-model:FP32",
        firstSeenAt: Date.now,
        lastSeen: Date.now,
        providerIdentifiers: "xcode preview",
        modelIdentifiers: [:],
        combinedInferenceParameters: JSONObject.string("98.6ºC"),
        stats: [:],
        label: [:]
    )
}

#Preview {
    struct ViewHolder: View {
        let providerService = ProviderService()

        init() {
            providerService.allModels = [
                makeFakeModel()
            ]
        }

        var body: some View {
            ModelPickerView(modelSelection: nil)
                .environment(providerService)
                .frame(width: 800, height: 600)
        }
    }

    return ViewHolder()
}

#Preview {
    struct ViewHolder: View {
        let providerService = ProviderService()
        @State var modelSelection: InferenceModel? = nil

        init() {
            providerService.allModels = [
                makeFakeModel()
            ]
        }

        var body: some View {
            ModelPickerView(modelSelection: $modelSelection)
                .environment(providerService)
                .frame(width: 800, height: 600)
        }
    }

    return ViewHolder()
}
