import SwiftData
import SwiftUI

enum StoredTextType: Codable, Hashable {
    case systemPromptOverride
    case modelTemplate
    case assistantResponseSeed
    case inferenceOptions
    case retrievalOptions
    case invalid
}

@Model
class StoredText {
    @Model
    class Key: Codable, Hashable {
        var contentType: StoredTextType
        var targetModel: FoundationModelRecordID?

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

    var content: String
    var createdAt: Date
    var key: Key

    init(
        content: String,
        createdAt: Date,
        key: Key
    ) {
        self.content = content
        self.createdAt = createdAt
        self.key = key
    }
}

@Observable
class Templates {
    private var modelContext: ModelContext

    // List of models loaded from ModelContainer
    //
    // - if value is nil, it means nothing was loaded
    // - if value is empty list, we tried loading, and nothing existed
    //
    @ObservationIgnored @Published
    private var loadedTemplates: [StoredText.Key : [StoredText]] = [:]

    public init(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func load(
        key: StoredText.Key,
        n: Int
    ) {
        let fetchDescriptor = FetchDescriptor<StoredText>(
            predicate: #Predicate<StoredText>{
                $0.key.contentType == key.contentType
                && $0.key.targetModel == key.targetModel
            },
            sortBy: [SortDescriptor(\StoredText.createdAt, order: .reverse)]
        )

        if loadedTemplates[key] == nil {
            loadedTemplates[key] = []
        }

        if let results = try? self.modelContext.fetch(fetchDescriptor) {
            loadedTemplates[key]!.append(contentsOf: results)
        }
    }

    func recents(
        type: StoredTextType,
        model: FoundationModelRecordID?,
        n: Int = 8
    ) -> [StoredText] {
        let key = StoredText.Key(contentType: type, targetModel: model)

        if loadedTemplates[key] == nil {
            load(key: key, n: n)
        }

        return loadedTemplates[key]!
    }

    func add(
        _ content: String,
        type: StoredTextType,
        model: FoundationModelRecordID?
    ) {
        let key = StoredText.Key(contentType: type, targetModel: model)

        let templateModel = StoredText(
            content: content,
            createdAt: Date.now,
            key: key)

        modelContext.insert(templateModel)
        if modelContext.hasChanges {
            do {
                try modelContext.save()
                print("[TRACE] Saved new template: \(templateModel.content)")
            }
            catch {
                print("[ERROR] Failed to save new template: \(templateModel.content)")
            }
        }
        else {
            print("[TRACE] Ignoring new template (no changes): \(templateModel.content)")
        }

        // Save it to list of loadedTemplates
        if loadedTemplates[key] == nil {
            loadedTemplates[key] = []
        }

        loadedTemplates[key]!.append(templateModel)
    }
}
