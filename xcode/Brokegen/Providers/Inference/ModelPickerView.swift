import SwiftUI

fileprivate let INVALID_MODEL_ID: InferenceModelRecordID = -4

struct ModelPickerView: View {
    @Environment(ProviderService.self) private var providerService
    @Environment(\.dismiss) var dismiss

    @Binding private var modelSelection: InferenceModel?
    private var enableModelSelection: Bool
    private var hideDismissButton: Bool
    @State private var isDismissButtonHovered: Bool = false

    init(
        modelSelection: Binding<InferenceModel?>? = nil
    ) {
        if modelSelection != nil {
            self._modelSelection = modelSelection!
            self.enableModelSelection = true
            self.hideDismissButton = false
        }
        else {
            self._modelSelection = Binding(
                get: { return nil },
                set: { newModel in
                }
            )
            self.enableModelSelection = false
            self.hideDismissButton = true
        }
    }

    var sortedModels: [InferenceModel] {
        get {
            providerService.allModels
            .sorted {
                if $0.firstSeenAt == nil {
                    return false
                }
                if $1.firstSeenAt == nil {
                    return false
                }
                return $0.firstSeenAt! > $1.firstSeenAt!
            }
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
                        ForEach(sortedModels) { model in
                            OneInferenceModelView(
                                model: model,
                                modelAvailable: providerService.availableModels.contains {
                                    $0.serverId == model.serverId
                                },
                                modelSelection: $modelSelection,
                                enableModelSelection: enableModelSelection
                            )
                        }
                    }

                    Text("End of loaded InferenceModels")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)

                List {
                    ForEach(sortedModels) { model in
                        OneInferenceModelView(
                            model: model,
                            modelAvailable: providerService.availableModels.contains {
                                $0.serverId == model.serverId
                            },
                            modelSelection: $modelSelection,
                            enableModelSelection: enableModelSelection
                        )
                        .expandContent(true)
                        .padding(24)
                        .padding(.bottom, 0)
                    }
                }

                Text("End of loaded InferenceModels")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .frame(height: 400)
                    .frame(maxWidth: .infinity)
            }

            if !hideDismissButton {
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
        }
        .onAppear {
            if providerService.availableModels.isEmpty {
                Task {
                    do { _ = try await providerService.fetchAllProviders() }
                    catch { print("[ERROR] Failed to providerService.fetchAllProviders()") }

                    do { try await providerService.fetchAvailableModels() }
                    catch { print("[ERROR] Failed to providerService.fetchAvailableModels()") }
                }
            }
        }
        .onChange(of: modelSelection) {
            dismiss.callAsFunction()
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
        combinedInferenceParameters: "98.6ºC",
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
