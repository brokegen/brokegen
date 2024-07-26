import SwiftData
import SwiftUI

enum StoredTextType: Codable, Hashable {
    case modelTemplate
}

@Model
class StoredText {
    var content: String
    var createdAt: Date

    struct Key: Codable, Hashable {
        var contentType: StoredTextType
        var targetModel: FoundationModelRecordID?
    }

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
    var loadedTemplates: [StoredText.Key : [StoredText]] = [:]

    public init(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func load(
        key: StoredText.Key,
        n: Int
    ) {
        let sortDescriptor = SortDescriptor(\StoredText.createdAt, order: .reverse)
        let fetchDescriptor = FetchDescriptor<StoredText>(sortBy: [sortDescriptor])

        if let results = try? self.modelContext.fetch(fetchDescriptor) {
            if loadedTemplates[key] == nil {
                loadedTemplates[key] = []
            }

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

        print("[TRACE] Saving new template: \(templateModel)")
        modelContext.insert(templateModel)

        if modelContext.hasChanges {
            try? modelContext.save()
        }

        // Save it to list of loadedTemplates
        if loadedTemplates[key] == nil {
            loadedTemplates[key] = []
        }

        loadedTemplates[key]!.append(templateModel)
    }
}
