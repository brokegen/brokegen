import SwiftUI

extension Font.Design {
    static func fromString(_ s: String) -> Font.Design {
        switch(s) {
        case "serif":
            Font.Design.serif
        case "rounded":
            Font.Design.rounded
        case "monospaced":
            Font.Design.monospaced
        default:
            Font.Design.default
        }
    }

    func toString() -> String {
        switch(self) {
        case .default:
            "default"
        case .serif:
            "serif"
        case .rounded:
            "rounded"
        case .monospaced:
            "monospaced"
        @unknown default:
            ""
        }
    }
}

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

    // NB This is the stringified name for Font.Design
    @AppStorage("defaultUiSettings.messageFontDesign")
    var _messageFontDesign: String = ""

    var messageFontDesign: Font.Design {
        get { Font.Design.fromString(_messageFontDesign) }
        set { _messageFontDesign = newValue.toString() }
    }

    @AppStorage("defaultUiSettings.responseBufferMaxSize")
    var responseBufferMaxSize: Int = 48

    @AppStorage("defaultUiSettings.scrollToBottomOnNew")
    var scrollToBottomOnNew: Bool = true

    @AppStorage("defaultUiSettings.animateNewResponseText")
    var animateNewResponseText: Bool = false

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
    var animateNewResponseText: Bool? = nil

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
