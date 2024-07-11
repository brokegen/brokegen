import SwiftUI

struct PersistentDefaultCSUISettings {
    @AppStorage("defaultUiSettings.allowContinuation")
    var allowContinuation: Bool = true

    @AppStorage("defaultUiSettings.showSeparateRetrievalButton")
    var showSeparateRetrievalButton: Bool = true

    @AppStorage("defaultUiSettings.forceRetrieval")
    var forceRetrieval: Bool = false

//    @AppStorage("defaultUiSettings.pinChatSequenceDesc")
//    var pinChatSequenceDesc: Bool? = nil

    @AppStorage("defaultUiSettings.showMessageHeaders")
    var showMessageHeaders: Bool = false

    @AppStorage("defaultUiSettings.renderAsMarkdown")
    var renderAsMarkdown: Bool = true

    @AppStorage("defaultUiSettings.responseBufferMaxSize")
    var responseBufferMaxSize: Int = 48

    @AppStorage("defaultUiSettings.scrollToBottomOnNew")
    var scrollToBottomOnNew: Bool = true

    @AppStorage("defaultUiSettings.showOIMPicker")
    var showOIMPicker: Bool = false

    @AppStorage("defaultUiSettings.stayAwakeDuringInference")
    var stayAwakeDuringInference: Bool = true
}

struct OverrideCSUISettings {
    var allowContinuation: Bool? = nil
    var showSeparateRetrievalButton: Bool? = nil
    var forceRetrieval: Bool? = nil

    var pinChatSequenceDesc: Bool? = nil
    var showMessageHeaders: Bool? = nil
    var renderAsMarkdown: Bool? = nil
    var scrollToBottomOnNew: Bool? = nil

    var showOIMPicker: Bool? = nil
    var stayAwakeDuringInference: Bool? = nil
}

struct CSInferenceSettings {
    enum AutonamingPolicy: String {
        case serverDefault, disable, summarizeAfterAsync, summarizeBefore
    }

    var inferenceOptions: String? = nil
    var overrideModelTemplate: String? = nil
    var overrideSystemPrompt: String? = nil
    var seedAssistantResponse: String? = nil

    var retrievalPolicy: String? = "simple"
    var retrievalSearchArgs: String? = "{\"k\": 18}"

    var autonamingPolicy: AutonamingPolicy = .serverDefault
}
