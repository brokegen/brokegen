import SwiftUI

/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: InferenceModelRecordID = -1

class SettingsService {
    @Bindable public var inferenceModelSettings: InferenceModelSettings = InferenceModelSettings()
    @Bindable public var sequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()

    @AppStorage("defaultInferenceModelId")
    private var defaultInferenceModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("fallbackInferenceModelId")
    private var fallbackInferenceModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("chatSummaryModelId")
    private var chatSummaryModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("preferredEmbeddingModelId")
    private var preferredEmbeddingModelId: InferenceModelRecordID = INVALID_MODEL_ID


    func inflateModels(_ providerService: ProviderService) {
        if inferenceModelSettings.defaultInferenceModel?.serverId != defaultInferenceModelId {
            inferenceModelSettings.defaultInferenceModel = providerService.allModels.first {
                $0.serverId == defaultInferenceModelId
            }
            print("InferenceModelSettingsService.defaultInferenceModel: \(defaultInferenceModelId) / \(inferenceModelSettings.defaultInferenceModel)")
        }

        if inferenceModelSettings.fallbackInferenceModel?.serverId != fallbackInferenceModelId {
            inferenceModelSettings.fallbackInferenceModel = providerService.allModels.first {
                $0.serverId == fallbackInferenceModelId
            }
            print("InferenceModelSettingsService.fallbackInferenceModel: \(fallbackInferenceModelId) / \(inferenceModelSettings.fallbackInferenceModel)")
        }

        if inferenceModelSettings.chatSummaryModel?.serverId != chatSummaryModelId {
            inferenceModelSettings.chatSummaryModel = providerService.allModels.first {
                $0.serverId == chatSummaryModelId
            }
        }

        if inferenceModelSettings.preferredEmbeddingModel?.serverId != preferredEmbeddingModelId {
            inferenceModelSettings.preferredEmbeddingModel = providerService.allModels.first {
                $0.serverId == preferredEmbeddingModelId
            }
        }

        inferenceModelSettings.stillPopulating = false
    }
}
