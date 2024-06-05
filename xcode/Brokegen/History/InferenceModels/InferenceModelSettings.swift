import SwiftUI

/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: InferenceModelRecordID = -1

class InferenceModelSettings: Observable, ObservableObject {
    var defaultInferenceModel: InferenceModel? = nil
    var fallbackInferenceModel: InferenceModel? = nil
    var chatSummaryModel: InferenceModel? = nil
    var embeddingModel: InferenceModel? = nil

    @AppStorage("defaultInferenceModelId")
    var defaultInferenceModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("fallbackInferenceModelId")
    var fallbackInferenceModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("chatSummaryModelId")
    var chatSummaryModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("embeddingModelId")
    var embeddingModelId: InferenceModelRecordID = INVALID_MODEL_ID


    func inflateModels(_ providerService: ProviderService) -> Self {
        if defaultInferenceModel?.serverId != defaultInferenceModelId {
            defaultInferenceModel = providerService.allModels.first {
                $0.serverId == defaultInferenceModelId
            }
            print("InferenceModelSettings.defaultInferenceModel: \(defaultInferenceModelId) / \(defaultInferenceModel)")
        }

        if fallbackInferenceModel?.serverId != fallbackInferenceModelId {
            fallbackInferenceModel = providerService.allModels.first {
                $0.serverId == fallbackInferenceModelId
            }
            print("InferenceModelSettings.fallbackInferenceModel: \(fallbackInferenceModelId) / \(fallbackInferenceModel)")
        }

        if chatSummaryModel?.serverId != chatSummaryModelId {
            chatSummaryModel = providerService.allModels.first {
                $0.serverId == chatSummaryModelId
            }
        }

        if embeddingModel?.serverId != embeddingModelId {
            embeddingModel = providerService.allModels.first {
                $0.serverId == embeddingModelId
            }
        }

        objectWillChange.send()
        return self
    }

    func defaultInferenceModelBinding() -> Binding<InferenceModel?> {
        return Binding(
            get: { return self.defaultInferenceModel },
            set: { value in
                self.defaultInferenceModel = value
                self.defaultInferenceModelId = value?.serverId ?? INVALID_MODEL_ID
                self.objectWillChange.send()
            }
        )
    }

    func fallbackInferenceModelBinding() -> Binding<InferenceModel?> {
        return Binding(
            get: { return self.fallbackInferenceModel },
            set: { value in
                self.fallbackInferenceModel = value
                self.fallbackInferenceModelId = value?.serverId ?? INVALID_MODEL_ID
                self.objectWillChange.send()
            }
        )
    }

    func chatSummaryModelBinding() -> Binding<InferenceModel?> {
        return Binding(
            get: { return self.chatSummaryModel },
            set: { value in
                self.chatSummaryModel = value
                self.chatSummaryModelId = value?.serverId ?? INVALID_MODEL_ID
                self.objectWillChange.send()
            }
        )
    }

    func embeddingModelBinding() -> Binding<InferenceModel?> {
        return Binding(
            get: { return self.embeddingModel },
            set: { value in
                self.embeddingModel = value
                self.embeddingModelId = value?.serverId ?? INVALID_MODEL_ID
                self.objectWillChange.send()
            }
        )
    }
}

extension InferenceModelSettings: Equatable {
    public static func == (lhs: InferenceModelSettings, rhs: InferenceModelSettings) -> Bool {
        return lhs.defaultInferenceModel == rhs.defaultInferenceModel
        && lhs.fallbackInferenceModel == rhs.fallbackInferenceModel
        && lhs.chatSummaryModel == rhs.chatSummaryModel
        && lhs.embeddingModel == rhs.embeddingModel
    }
}

extension InferenceModelSettings: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(defaultInferenceModel)
        hasher.combine(fallbackInferenceModel)
        hasher.combine(chatSummaryModel)
        hasher.combine(embeddingModel)
    }
}
