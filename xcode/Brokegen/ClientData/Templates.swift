import SwiftData
import SwiftUI

@Model
class StoredTemplate {
    var content: String
    var targetModel: FoundationModelRecordID?
    var createdAt: Date

    init(
        content: String,
        targetModel: FoundationModelRecordID?,
        createdAt: Date
    ) {
        self.content = content
        self.targetModel = targetModel
        self.createdAt = createdAt
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
    var loadedTemplates: [FoundationModelRecordID? : [StoredTemplate]] = [:]

    public init(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadTemplates(
        model: FoundationModelRecordID? = nil,
        n: Int
    ) {
        let sortDescriptor = SortDescriptor(\StoredTemplate.createdAt, order: .reverse)
        let fetchDescriptor = FetchDescriptor<StoredTemplate>(sortBy: [sortDescriptor])

        if let results = try? self.modelContext.fetch(fetchDescriptor) {
            if loadedTemplates[model] == nil {
                loadedTemplates[model] = []
            }

            for result in results {
                print("[TRACE] Loaded template \"\(result.content)\"")
            }

            loadedTemplates[model]!.append(contentsOf: results)
        }
    }

    func recentTemplates(
        _ model: FoundationModelRecordID? = nil,
        n: Int = 8
    ) -> [StoredTemplate] {
        if loadedTemplates[model] == nil {
            loadTemplates(model: model, n: n)
        }

        return loadedTemplates[model]!
    }

    func add(
        template: String,
        model: FoundationModelRecordID?
    ) {
        let templateModel = StoredTemplate(
            content: template,
            targetModel: model,
            createdAt: Date.now)

        print("[TRACE] Saving new template: \(template)")
        modelContext.insert(templateModel)

        if modelContext.hasChanges {
            try? modelContext.save()
        }

        // Save it to list of loadedTemplates
        if loadedTemplates[model] == nil {
            loadedTemplates[model] = []
        }

        loadedTemplates[model]!.append(templateModel)
    }
}
