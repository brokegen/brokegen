import Foundation
import SwiftData


enum StoredTextType: String, Codable, Hashable {
    case systemPromptOverride
    case modelTemplate
    case assistantResponseSeed
    case inferenceOptions
    case retrievalSearchArgs
    case invalid
}

@Model
class StoredTextKey: Codable {
    let contentType: StoredTextType
    let targetModel: FoundationModelRecordID?

    init(
        contentType: StoredTextType,
        targetModel: FoundationModelRecordID?
    ) {
        self.contentType = contentType
        self.targetModel = targetModel
    }

    enum CodingKeys: CodingKey {
        case contentType, targetModel
    }

    required init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        contentType = (try? container?.decodeIfPresent(StoredTextType.self, forKey: .contentType)) ?? .invalid
        targetModel = try? container?.decodeIfPresent(FoundationModelRecordID.self, forKey: .targetModel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(targetModel, forKey: .targetModel)
    }
}

extension StoredTextKey: CustomStringConvertible {
    var description: String {
        return "StoredText.Key: .\(contentType.rawValue), \(targetModel)"
    }
}

// NB We must implement Equatable, otherwise @Model classes will result in duplicate dictionary keys.
extension StoredTextKey: Equatable, Hashable {
    public static func == (lhs: StoredTextKey, rhs: StoredTextKey) -> Bool {
        lhs.contentType == rhs.contentType
        && lhs.targetModel == rhs.targetModel
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(contentType)
        hasher.combine(targetModel)
    }
}

@Model
class StoredText {
    var content: String
    var createdAt: Date
    @Relationship
    var key: StoredTextKey

    init(
        content: String,
        createdAt: Date,
        key: StoredTextKey
    ) {
        self.content = content
        self.createdAt = createdAt
        self.key = key
    }
}
