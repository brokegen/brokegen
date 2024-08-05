import SwiftData
import XCTest

@testable import Brokegen


final class StoredTextTests: XCTestCase {
    func testSttDict() {
        var testDict: [StoredTextType : [Int]?] = [:]

        testDict[.modelTemplate] = [1]
        testDict[.modelTemplate] = [2]

        let keyA = StoredTextType.inferenceOptions
        let keyB = StoredTextType.inferenceOptions

        testDict[keyA] = [3]
        testDict[keyB] = [4]

        assert(testDict.keys.count == 2)
        assert(testDict[.modelTemplate] == [2])
        assert(testDict[.inferenceOptions] == [4])

        testDict[keyA] = nil
        assert(testDict.keys.count == 1)
        testDict[keyB] = [5]
        assert(testDict.keys.count == 2)
    }

    func testStkEquals() {
        let stk1a = StoredTextKey(contentType: .inferenceOptions, targetModel: 47)
        let stk1b = StoredTextKey(contentType: .inferenceOptions, targetModel: 47)
        let stk2a = StoredTextKey(contentType: .inferenceOptions, targetModel: nil)
        let stk2b = StoredTextKey(contentType: .inferenceOptions, targetModel: nil)

        assert(stk1a == stk1a)
        assert(stk1a == stk1b)
        assert(stk1a != stk2a)
        assert(stk2a == stk2a)
        assert(stk2a == stk2b)
    }

    func testStkDict() {
        var testDict: [StoredTextKey : [Int]?] = [:]

        let stk1a = StoredTextKey(contentType: .inferenceOptions, targetModel: 47)
        let stk1b = StoredTextKey(contentType: .inferenceOptions, targetModel: 47)
        let stk2 = StoredTextKey(contentType: .modelTemplate, targetModel: 48)

        testDict[stk1a] = [1]
        testDict[stk1b] = [2]
        testDict[stk2] = [3]

        assert(testDict.keys.count == 2)
    }

    // Smoke test: insert one, expect one
    @MainActor
    func testStkInsert() throws {
        let container = try ModelContainer(
            for: StoredTextKey.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = container.mainContext

        let stk1a = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 49)

        modelContext.insert(stk1a)
        try modelContext.save()

        let allKeys = try modelContext.fetch(
            FetchDescriptor<StoredTextKey>()
        )
        assert(allKeys.count == 1)
    }

    @MainActor
    func testStkInsertIdentifiableDuplicate() throws {
        let container = try ModelContainer(
            for: StoredTextKey.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = container.mainContext

        let stk1a = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 49)

        modelContext.insert(stk1a)
        modelContext.insert(stk1a)
        try modelContext.save()

        let allKeys = try modelContext.fetch(
            FetchDescriptor<StoredTextKey>()
        )
        assert(allKeys.count == 1)
    }

    @MainActor
    func skipped_testStkInsertEquatableDuplicate() throws {
        let container = try ModelContainer(
            for: StoredTextKey.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = container.mainContext

        let stk1a = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 49)
        let stk1b = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 49)

        modelContext.insert(stk1a)
        modelContext.insert(stk1b)
        try modelContext.save()

        let allKeys = try modelContext.fetch(
            FetchDescriptor<StoredTextKey>()
        )
        assert(allKeys.count == 1)
    }

    @MainActor
    func skipped_testStkInsertComplex() throws {
        let container = try ModelContainer(
            for: StoredTextKey.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = container.mainContext

        let stk1a = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 49)
        let stk1b = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 49)
        let stk2 = StoredTextKey(contentType: .assistantResponseSeed, targetModel: 50)
        let stk3 = StoredTextKey(contentType: .systemPromptOverride, targetModel: 49)

        modelContext.insert(stk1a)
        modelContext.insert(stk1a)
        modelContext.insert(stk1b)
        try modelContext.save()

        let allKeys = try modelContext.fetch(
            FetchDescriptor<StoredTextKey>()
        )
        // TODO: This will only work once StoredTextKey does SwiftData-appropriate deduplicating
        assert(allKeys.count == 1)

        modelContext.insert(stk2)
        modelContext.insert(stk3)
        try modelContext.save()

        let allKeys2 = try modelContext.fetch(
            FetchDescriptor<StoredTextKey>()
        )
        assert(allKeys2.count == 3)
    }

    @MainActor
    func testStkModel() throws {
        let container = try ModelContainer(
            for: StoredTextKey.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        let templates = Templates(container)
        let stk1a = templates.fetchTextKey(contentType: .assistantResponseSeed, targetModel: 49)
        let stk1b = templates.fetchTextKey(contentType: .assistantResponseSeed, targetModel: 49)

        let allKeys = try container.mainContext.fetch(
            FetchDescriptor<StoredTextKey>()
        )
        assert(allKeys.count == 1)
    }
}
