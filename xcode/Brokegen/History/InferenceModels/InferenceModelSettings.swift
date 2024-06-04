import SwiftUI

class InferenceModelSettings: Observable, ObservableObject {
    var defaultInferenceModel: InferenceModel? = nil
    var fallbackInferenceModel: InferenceModel? = nil
    var chatSummaryModel: InferenceModel? = nil
    var embeddingModel: InferenceModel? = nil
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
