import SwiftData
import SwiftUI

@Observable
class Templates {
    private var modelContext: ModelContext

    // List of models loaded from ModelContainer
    //
    // - if value is nil, it means nothing was loaded
    // - if value is empty list, we tried loading, and nothing existed
    //
    @ObservationIgnored @Published
    private var loadedTemplates: [StoredTextKey : [StoredText]] = [:]

    public init(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchTextKey(
        contentType: StoredTextType,
        targetModel: FoundationModelRecordID?
    ) -> StoredTextKey {
        let newKey = StoredTextKey(contentType: contentType, targetModel: targetModel)

        let fetchDescriptor = FetchDescriptor<StoredTextKey>(
            // NB #Predicate does not work with this expression. Don't use it.
            // predicate: #Predicate { $0 == newKey }
        )

        let results = try? self.modelContext.fetch(fetchDescriptor)
            .filter { $0 == newKey }

        if let theResult = results?.first {
            return theResult
        }
        else {
            modelContext.insert(newKey)
            if modelContext.hasChanges {
                try? modelContext.save()
            }

            return newKey
        }
    }

    private func add(
        content: String,
        contentType: StoredTextType,
        targetModel: FoundationModelRecordID?
    ) -> StoredText {
        let key = fetchTextKey(contentType: contentType, targetModel: targetModel)
        let st = StoredText(
            content: content,
            createdAt: Date.now,
            key: key)

        modelContext.insert(st)
        if modelContext.hasChanges {
            try? modelContext.save()
        }

        if loadedTemplates[key] == nil {
            loadedTemplates[key] = []
        }

        loadedTemplates[key]!.append(st)
        return st
    }

    func add(
        _ content: String,
        type: StoredTextType,
        model: FoundationModelRecordID?
    ) {
        _ = self.add(content: content, contentType: type, targetModel: model)
    }

    func recents(
        type: StoredTextType,
        model: FoundationModelRecordID,
        sharedFetchLimit: Int? = nil
    ) -> [StoredText] {
        let key = fetchTextKey(contentType: type, targetModel: model)
        if loadedTemplates[key] == nil {
            loadedTemplates[key] = []

            var fetchDescriptor = FetchDescriptor<StoredText>(
                sortBy: [SortDescriptor(\StoredText.createdAt, order: .reverse)]
            )
            fetchDescriptor.fetchLimit = sharedFetchLimit

            let results = try? self.modelContext.fetch(fetchDescriptor)
                .filter { $0.key == key }
            if results != nil {
                loadedTemplates[key]!.append(contentsOf: results!)
            }
        }

        return loadedTemplates[key]!
    }

    func recents(
        type: StoredTextType,
        n: Int? = nil
    ) -> [StoredText] {
        let fetchDescriptor = FetchDescriptor<StoredText>(
            sortBy: [SortDescriptor(\StoredText.createdAt, order: .reverse)]
        )

        let results = try? self.modelContext.fetch(fetchDescriptor)
            .filter { $0.key.contentType == type }
        for st: StoredText in results ?? [] {
            if loadedTemplates[st.key] == nil {
                loadedTemplates[st.key] = []
            }
            loadedTemplates[st.key]!.append(st)
        }

        if results == nil {
            return []
        }
        else if n == nil {
            return results!
        }
        else {
            return Array(results!.prefix(n!))
        }
    }
}
