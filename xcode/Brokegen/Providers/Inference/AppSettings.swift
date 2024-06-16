import SwiftUI

/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: InferenceModelRecordID = -3

@Observable
class AppSettings: ObservableObject {
    @AppStorage("defaultInferenceModelId")
    @ObservationIgnored private var defaultInferenceModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("fallbackInferenceModelId")
    @ObservationIgnored private var fallbackInferenceModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("chatSummaryModelId")
    @ObservationIgnored private var chatSummaryModelId: InferenceModelRecordID = INVALID_MODEL_ID
    @AppStorage("preferredEmbeddingModelId")
    @ObservationIgnored private var preferredEmbeddingModelId: InferenceModelRecordID = INVALID_MODEL_ID

    // MARK: - connecting ProviderService
    private var providerService: ProviderService? = nil

    func link(to providerService: ProviderService) {
        self.providerService = providerService
    }

    var stillPopulating: Bool {
        providerService == nil
    }

    // MARK: - retrieving fully populated models
    var defaultInferenceModel: InferenceModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == defaultInferenceModelId
            }
        }
        set {
            defaultInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    var fallbackInferenceModel: InferenceModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == fallbackInferenceModelId
            }
        }
        set {
            fallbackInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    var chatSummaryModel: InferenceModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == chatSummaryModelId
            }
        }
        set {
            chatSummaryModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    var preferredEmbeddingModel: InferenceModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == preferredEmbeddingModelId
            }
        }
        set {
            preferredEmbeddingModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }
}
