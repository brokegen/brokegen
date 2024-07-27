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
        targetModel: FoundationModelRecordID?,
        printSaved: Bool = false,
        printLoaded: Bool = false
    ) -> StoredTextKey {
        let newKey = StoredTextKey(contentType: contentType, targetModel: targetModel)

        let fetchDescriptor = FetchDescriptor<StoredTextKey>(
            // NB #Predicate does not work with this expression. Don't use it.
            // predicate: #Predicate { $0 == newKey }
        )

        let results = try? self.modelContext.fetch(fetchDescriptor)
            .filter { $0 == newKey }
        if (results?.count ?? 0) > 1 {
            fatalError("SwiftData model store contains \(results?.count) duplicate StoredTextKeys")
        }

        if let theResult = results?.first {
            return theResult
        }
        else {
            modelContext.insert(newKey)
            if modelContext.hasChanges {
                do {
                    try modelContext.save()
                    print("[TRACE] Saved new \(newKey)")
                }
                catch {
                    print("[ERROR] Failed to save new \(newKey)")
                }
            }
            else {
                print("[TRACE] Ignoring (no changes) for \(newKey)")
            }

            // Print the state _after_ any insert events.
            print("[DEBUG] fetchTextKey(): \(loadedTemplates.count) keys loaded")
            if printLoaded {
                for (k, vList) in loadedTemplates {
                    print("- \(k): \(vList.count) texts in list")
                    for v in vList {
                        print("  - \(k): \(v.content.replacingOccurrences(of: "\n", with: "\\n"))")
                    }
                }
            }

            let allKeys = try? self.modelContext.fetch(
                FetchDescriptor<StoredTextKey>()
            )
            print("[DEBUG] fetchTextKey(): \(allKeys?.count ?? -1) keys total in model store")
            if printSaved {
                for k: StoredTextKey in allKeys ?? [] {
                    print("- \(k)")
                }
            }

            print("")
            return newKey
        }
    }

    private func fetchText(
        content: String,
        contentType: StoredTextType,
        targetModel: FoundationModelRecordID?
    ) -> StoredText {
        let key = fetchTextKey(contentType: contentType, targetModel: targetModel)
        let fetchDescriptor = FetchDescriptor<StoredText>(
            sortBy: [SortDescriptor(\StoredText.createdAt)]
        )

        let results = try? self.modelContext.fetch(fetchDescriptor)
            .filter { $0.key == key && $0.content == content }
        if let theResult = results?.first {
            return theResult
        }
        else {
            let sText = StoredText(
                content: content,
                createdAt: Date.now,
                key: key)

            modelContext.insert(sText)
            if modelContext.hasChanges {
                do {
                    try modelContext.save()
                    print("[TRACE] Saved new StoredText: \(sText.content)")
                }
                catch {
                    print("[ERROR] Failed to save new StoredText: \(sText.content)")
                }
            }
            else {
                print("[TRACE] Ignoring new StoredText (no changes): \(sText.content)")
            }

            // Save it to loadedTemplates
            if loadedTemplates[key] == nil {
                loadedTemplates[key] = []
            }

            loadedTemplates[key]!.append(sText)
            return sText
        }
    }

    func add(
        _ content: String,
        type: StoredTextType,
        model: FoundationModelRecordID?
    ) {
        _ = self.fetchText(content: content, contentType: type, targetModel: model)
    }

    private func load(
        key: StoredTextKey,
        n: Int?,
        printSaved: Bool = true,
        printLoaded: Bool = true
    ) {
        if loadedTemplates[key] == nil {
            loadedTemplates[key] = []
        }

        var fetchDescriptor = FetchDescriptor<StoredText>(
            sortBy: [SortDescriptor(\StoredText.createdAt, order: .reverse)]
        )
        fetchDescriptor.fetchLimit = n

        let results = try? self.modelContext.fetch(fetchDescriptor)
            .filter { $0.key == key }
        if results != nil {
            loadedTemplates[key]!.append(contentsOf: results!)
        }
        else {
            print("[INFO] Failed to find any matching StoredTexts for \(key)")

            print("[DEBUG] loadedTemplates has \(loadedTemplates.count) keys")
            if printLoaded {
                for (k, vList) in loadedTemplates {
                    print("- \(k): \(vList.count) texts in list")
                    for v in vList {
                        print("  - \(k): \(v.content.replacingOccurrences(of: "\n", with: "\\n"))")
                    }
                }
            }

            let allTexts = try? self.modelContext.fetch(
                FetchDescriptor<StoredText>()
            )
            print("[DEBUG] Total number of StoredTexts is \(allTexts?.count ?? -1)")
            if printSaved {
                for t: StoredText in allTexts ?? [] {
                    print("- \(t.key): \(t.content.replacingOccurrences(of: "\n", with: "\\n"))")
                }
            }
        }
    }

    func recents(
        type: StoredTextType,
        model: FoundationModelRecordID?,
        // NB Due to how FetchDescriptors aren't working, this value would be applied pre-filtering.
        n: Int? = nil
    ) -> [StoredText] {
        let key = fetchTextKey(contentType: type, targetModel: model)
        if loadedTemplates[key] == nil {
            self.load(key: key, n: n)
        }

        return loadedTemplates[key]!
    }
}
