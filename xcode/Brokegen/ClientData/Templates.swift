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

    private func fetchTextKey(
        contentType: StoredTextType,
        targetModel: FoundationModelRecordID?,
        printSaved: Bool = false,
        printLoaded: Bool = true
    ) -> StoredTextKey {
        let newKey = StoredTextKey(contentType: contentType, targetModel: targetModel)
        let fetchDescriptor = FetchDescriptor<StoredTextKey>(
            predicate: #Predicate {
                $0.contentType == newKey.contentType
                && $0.targetModel == newKey.targetModel
            }
        )

        let results = try? self.modelContext.fetch(fetchDescriptor)
        if let theResult = results?.first {
            // If found, it should be in our local list already, so just exit
            return theResult
        }
        else {
            // Print debug info for current state
            print("[INFO] Failed to find any matching StoredTextKeys for \(newKey)")

            print("[DEBUG] loadedTemplates has \(loadedTemplates.count) keys")
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
            print("[DEBUG] Total number of StoredTextKeys is \(allKeys?.count ?? -1)")
            if printSaved {
                for k: StoredTextKey in allKeys ?? [] {
                    print("- \(k)")
                }
            }

            // Actually add it to context
            let key = StoredTextKey(contentType: contentType, targetModel: targetModel)

            modelContext.insert(key)
            if modelContext.hasChanges {
                do {
                    try modelContext.save()
                    print("[TRACE] Saved new \(key)")
                }
                catch {
                    print("[ERROR] Failed to save new \(key)")
                }
            }
            else {
                print("[TRACE] Ignoring (no changes) for \(key)")
            }

            return key
        }
    }

    private func fetchText(
        content: String,
        contentType: StoredTextType,
        targetModel: FoundationModelRecordID?
    ) -> StoredText {
        let key = fetchTextKey(contentType: contentType, targetModel: targetModel)
        let fetchDescriptor = FetchDescriptor<StoredText>(
            predicate: #Predicate {
                $0.key == key
                && $0.content == content
            },
            sortBy: [SortDescriptor(\StoredText.createdAt)]
        )

        let results = try? self.modelContext.fetch(fetchDescriptor)
        if let theResult = results?.first {
            // If found, it should be in our local list already, so just exit
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
            predicate: #Predicate {
                $0.key == key
            },
            sortBy: [SortDescriptor(\StoredText.createdAt, order: .reverse)]
        )
        fetchDescriptor.fetchLimit = n

        if let results = try? self.modelContext.fetch(fetchDescriptor) {
            loadedTemplates[key]!.append(contentsOf: results)
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
        n: Int? = 8
    ) -> [StoredText] {
        let key = fetchTextKey(contentType: type, targetModel: model)
        if loadedTemplates[key] == nil {
            self.load(key: key, n: n)
        }

        return loadedTemplates[key]!
    }
}
