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

    @MainActor
    static func fromInMemory() -> Templates {
        let schema = Schema([
            StoredTextKey.self,
            StoredText.self,
        ])

        do {
            let modelContainer = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(isStoredInMemoryOnly: true)
                ])
            return Templates(modelContainer)
        }
        catch {
            fatalError("[ERROR] Could not create in-memory ModelContainer!: \(error)")
        }
    }

    @MainActor
    static func fromPath(
        _ containerFilename: String = "client-only.sqlite"
    ) throws -> Templates {
        let schema = Schema([
            StoredTextKey.self,
            StoredText.self,
        ])

        let storePath = URL.applicationSupportDirectory
        // We manually append the path component because unsigned apps get special problems.
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appending(path: containerFilename)

        let modelContainer = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: storePath),
            ])
        return Templates(modelContainer)
    }

    @MainActor
    public init(_ modelContainer: ModelContainer) {
        self.modelContext = modelContainer.mainContext

        // Do initial population of some templates
        if recents(type: .retrievalSearchArgs).isEmpty {
            _ = add(
                // TODO: We haven't really figured out prompt size/tuning yet, but default k=18 works for our dataset.
                // More specifically, how to configure it in a reasonable way.
                content: """
                {
                  "k": 18,
                  "fetch_k": 60,
                  "lambda_mult": 0.25
                }
                """,
                contentType: .retrievalSearchArgs,
                targetModel: nil)
        }

        if recents(type: .inferenceOptions).isEmpty {
            _ = add(
                // These are specified in the high-level llama_cpp API:
                // https://llama-cpp-python.readthedocs.io/en/latest/api-reference/#high-level-api
                //
                // This is a combined list of llama_cpp.Llama.__init__() args and llama_cpp.Llama.create_completion().
                // TODO: Figure out a way to surface this URL to the end user
                content: """
                {
                  "n_ctx": 80000,
                  "last_n_tokens_size": 512,
                  "repeat_penalty": 1.0,
                  "max_tokens": 1024,
                  "min_p": 0.05,
                  "n_gpu_layers": -1,
                  "n_threads": 9,
                  "temperature": 0.8,
                  "verbose": true
                }
                """,
                contentType: .inferenceOptions,
                targetModel: nil
            )
        }
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

    func add(
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

    func recents(
        type: StoredTextType,
        model: FoundationModelRecordID?,
        sharedFetchLimit: Int? = nil
    ) -> [StoredText] {
        if model == nil {
            return recents(type: type, n: sharedFetchLimit)
        }

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
