import Foundation
import SwiftData

enum ModelNeeds: Codable, CaseIterable {
    case inferenceDefault, chatSummary, embedding
}

@Model
class InferenceModelSettings: Codable {
    var storedModelNeeds: [ModelNeeds : InferenceModelRecordID] = [:]

    required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.storedModelNeeds = try container.decode(
            [ModelNeeds : InferenceModelRecordID].self
        )
    }

    init(from: InferenceModelSettings) {
        self.storedModelNeeds = from.storedModelNeeds
    }

    func get(for modelNeed: ModelNeeds) -> InferenceModelRecordID? {
        return storedModelNeeds[modelNeed]
    }

    func set(_ inferenceModelId: InferenceModelRecordID, for modelNeed: ModelNeeds) {
        storedModelNeeds[modelNeed] = inferenceModelId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedModelNeeds)
    }
}
