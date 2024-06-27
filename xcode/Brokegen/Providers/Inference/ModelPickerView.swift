import SwiftUI

fileprivate let INVALID_MODEL_ID: FoundationModelRecordID = -4

struct ModelPickerView: View {
    @Environment(ProviderService.self) private var providerService
    @Environment(\.dismiss) var dismiss

    @Binding private var modelSelection: FoundationModel?
    private var enableModelSelection: Bool
    @State private var expandNeverUsedModels: Bool = false
    private var hideDismissButton: Bool
    @State private var isDismissButtonHovered: Bool = false

    init(
        modelSelection: Binding<FoundationModel?>? = nil
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

    var usedModels: [FoundationModel] {
        get {
            providerService.allModels
                .filter { $0.latestInferenceEvent != nil }
                .sorted {
                    $0.recentTokensPerSecond > $1.recentTokensPerSecond
                }
                .sorted {
                    $0.latestInferenceEvent ?? Date.distantPast
                    > $1.latestInferenceEvent ?? Date.distantPast
                }
        }
    }

    var neverUsedModels: [FoundationModel] {
        get {
            providerService.allModels
                .filter { $0.latestInferenceEvent == nil }
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

    func isModelAvailable(_ model: FoundationModel) -> Binding<Bool> {
        return Binding(
            get: { return self.providerService.availableModels.contains { $0.serverId == model.serverId } },
            set: { _ in }
        )
    }

    var body: some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .top)) {
            ViewThatFits(in: .horizontal) {
                // TODO: ViewThatFits will just pop in and out of existence, willy-nilly.
                // Which makes it very hard to track items in a particular spot,
                // especially since sorting is virtually random.
                ScrollView {
                    if !usedModels.isEmpty {
                        VFlowLayout(spacing: 24) {
                            ForEach(usedModels) { model in
                                OneFoundationModelView(
                                    model: model,
                                    modelAvailable: isModelAvailable(model),
                                    expandContent: expandNeverUsedModels || usedModels.count < 6,
                                    modelSelection: $modelSelection,
                                    enableModelSelection: enableModelSelection
                                )
                            }
                        }

                        Divider()
                            .padding(24)
                    }

                    if expandNeverUsedModels {
                        VFlowLayout(spacing: 24) {
                            ForEach(neverUsedModels) { model in
                                OneFoundationModelView(
                                    model: model,
                                    modelAvailable: isModelAvailable(model),
                                    modelSelection: $modelSelection,
                                    enableModelSelection: enableModelSelection
                                )
                            }
                        }
                    }
                    else {
                        Toggle(isOn: $expandNeverUsedModels) {
                            Label("Show never-used models", systemImage: "chevron.down")
                                .padding(24)
                                .font(.system(size: 24))
                        }
                        .toggleStyle(.button)
                        .disabled(neverUsedModels.isEmpty)
                    }

                    Text("End of loaded FoundationModels")
                        .foregroundStyle(Color(.disabledControlTextColor))
                        .frame(height: 400)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
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
        .background(BackgroundEffectView().ignoresSafeArea())
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

struct RefreshableModelPickerView: View {
    @Environment(ProviderService.self) private var providerService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { try? await providerService.fetchAvailableModels() }
                }
                .buttonStyle(.accessoryBar)
                .padding(12)
                .layoutPriority(0.2)

                Spacer()
            }
            ModelPickerView()
        }
    }
}

fileprivate func makeFakeModel() -> FoundationModel {
    return FoundationModel(
        id: UUID(),
        serverId: 1000,
        humanId: "test-model:FP32",
        firstSeenAt: Date.now,
        lastSeen: Date.now,
        providerIdentifiers: "xcode preview",
        modelIdentifiers: nil,
        combinedInferenceParameters: "98.6ºC",
        displayStats: nil,
        allStats: nil,
        label: nil,
        available: true,
        latestInferenceEvent: nil,
        recentInferenceEvents: 0,
        recentTokensPerSecond: 0.0
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
        @State var modelSelection: FoundationModel? = nil

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
