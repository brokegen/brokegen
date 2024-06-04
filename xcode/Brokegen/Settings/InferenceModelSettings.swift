import Foundation
import SwiftData

enum ModelNeeds: Codable, CaseIterable {
    case inferenceDefault, chatSummary, embedding
}

class InferenceModelSettings: Codable, Observable {
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

    init() {}

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

extension InferenceModelSettings: Equatable {
    static func == (lhs: InferenceModelSettings, rhs: InferenceModelSettings) -> Bool {
        return lhs.storedModelNeeds == rhs.storedModelNeeds
    }
}

extension InferenceModelSettings: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(storedModelNeeds)
    }
}
