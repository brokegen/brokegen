import SwiftUI

struct PersistentDefaultCSUISettings {
    @AppStorage("defaultUiSettings.allowContinuation")
    var allowContinuation: Bool = true

    @AppStorage("defaultUiSettings.showSeparateRetrievalButton")
    var showSeparateRetrievalButton: Bool = true

    @AppStorage("defaultUiSettings.forceRetrieval")
    var forceRetrieval: Bool = false

    // Placeholder: non-global settings

    @AppStorage("defaultUiSettings.showOIMPicker")
    var showOIMPicker: Bool = false

    @AppStorage("defaultUiSettings.allowNewlineSubmit")
    var allowNewlineSubmit: Bool = false

    @AppStorage("defaultUiSettings.stayAwakeDuringInference")
    var stayAwakeDuringInference: Bool = true
}

struct OverrideCSUISettings {
    var allowContinuation: Bool? = nil
    var showSeparateRetrievalButton: Bool? = nil
    var forceRetrieval: Bool? = nil

    var pinChatSequenceDesc: Bool? = nil
    var showMessageHeaders: Bool? = nil

    var showOIMPicker: Bool? = nil
    var allowNewlineSubmit: Bool? = nil
    var stayAwakeDuringInference: Bool? = nil
}

struct CSInferenceSettings {
    enum ChatAutoNaming: String {
        case serverDefault, disable, summarizeAfterAsync, summarizeBefore
    }

    var inferenceOptions: String? = nil
    var overrideModelTemplate: String? = nil
    var overrideSystemPrompt: String? = nil
    var seedAssistantResponse: String? = nil

    var retrievalPolicy: String? = "simple"
    var retrievalSearchArgs: String? = "{\"k\": 18}"

    var autonamingPolicy: ChatAutoNaming = .serverDefault
}
