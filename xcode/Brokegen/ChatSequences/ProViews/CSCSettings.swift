import SwiftUI

/// @AppStorage needs a bit of manual plumbing to make it compatible with @Observable.
/// https://stackoverflow.com/questions/76606977/swift-ist-there-any-way-using-appstorage-with-observable
///
@Observable
class PersistentDefaultCSUISettings {
    @AppStorage("defaultUiSettings.allowContinuation")
    @ObservationIgnored private var _allowContinuation: Bool = true

    var allowContinuation: Bool {
        get {
            access(keyPath: \.allowContinuation)
            return _allowContinuation
        }
        set {
            withMutation(keyPath: \.allowContinuation) {
                _allowContinuation = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.showSeparateRetrievalButton")
    @ObservationIgnored private var _showSeparateRetrievalButton: Bool = true

    @ObservationIgnored
    var showSeparateRetrievalButton: Bool {
        get {
            access(keyPath: \.showSeparateRetrievalButton)
            return _showSeparateRetrievalButton
        }
        set {
            withMutation(keyPath: \.showSeparateRetrievalButton) {
                _showSeparateRetrievalButton = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.forceRetrieval")
    @ObservationIgnored var _forceRetrieval: Bool = false

    @ObservationIgnored
    var forceRetrieval: Bool {
        get {
            access(keyPath: \.forceRetrieval)
            return _forceRetrieval
        }
        set {
            withMutation(keyPath: \.forceRetrieval) {
                _forceRetrieval = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.showMessageHeaders")
    @ObservationIgnored var _showMessageHeaders: Bool = false

    @ObservationIgnored
    var showMessageHeaders: Bool {
        get {
            access(keyPath: \.showMessageHeaders)
            return _showMessageHeaders
        }
        set {
            withMutation(keyPath: \.showMessageHeaders) {
                _showMessageHeaders = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.renderAsMarkdown")
    @ObservationIgnored var _renderAsMarkdown: Bool = true

    @ObservationIgnored
    var renderAsMarkdown: Bool {
        get {
            access(keyPath: \.renderAsMarkdown)
            return _renderAsMarkdown
        }
        set {
            withMutation(keyPath: \.renderAsMarkdown) {
                _renderAsMarkdown = newValue
            }
        }
    }

    // NB This is the stringified name for a Font.Design
    @AppStorage("defaultUiSettings.messageFontDesign")
    @ObservationIgnored var _messageFontDesign: String = ""

    @ObservationIgnored
    var messageFontDesign: String {
        get {
            access(keyPath: \.messageFontDesign)
            return _messageFontDesign
        }
        set {
            withMutation(keyPath: \.messageFontDesign) {
                _messageFontDesign = newValue
            }
        }
    }

    // NB This is the stringified name for a Font.Design
    @AppStorage("defaultUiSettings.textEntryFontDesign")
    @ObservationIgnored var _textEntryFontDesign: String = ""

    @ObservationIgnored
    var textEntryFontDesign: String {
        get {
            access(keyPath: \.textEntryFontDesign)
            return _textEntryFontDesign
        }
        set {
            withMutation(keyPath: \.textEntryFontDesign) {
                _textEntryFontDesign = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.responseBufferMaxSize")
    @ObservationIgnored var _responseBufferMaxSize: Int = 48

    @ObservationIgnored
    var responseBufferMaxSize: Int {
        get {
            access(keyPath: \.responseBufferMaxSize)
            return _responseBufferMaxSize
        }
        set {
            withMutation(keyPath: \.responseBufferMaxSize) {
                _responseBufferMaxSize = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.scrollToBottomOnNew")
    @ObservationIgnored var _scrollToBottomOnNew: Bool = true

    @ObservationIgnored
    var scrollToBottomOnNew: Bool {
        get {
            access(keyPath: \.scrollToBottomOnNew)
            return _scrollToBottomOnNew
        }
        set {
            withMutation(keyPath: \.scrollToBottomOnNew) {
                _scrollToBottomOnNew = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.animateNewResponseText")
    @ObservationIgnored var _animateNewResponseText: Bool = false

    @ObservationIgnored
    var animateNewResponseText: Bool {
        get {
            access(keyPath: \.animateNewResponseText)
            return _animateNewResponseText
        }
        set {
            withMutation(keyPath: \.animateNewResponseText) {
                _animateNewResponseText = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.showOIMPicker")
    @ObservationIgnored var _showOIMPicker: Bool = false

    @ObservationIgnored
    var showOIMPicker: Bool {
        get {
            access(keyPath: \.showOIMPicker)
            return _showOIMPicker
        }
        set {
            withMutation(keyPath: \.showOIMPicker) {
                _showOIMPicker = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.stayAwakeDuringInference")
    @ObservationIgnored var _stayAwakeDuringInference: Bool = true

    @ObservationIgnored
    var stayAwakeDuringInference: Bool {
        get {
            access(keyPath: \.stayAwakeDuringInference)
            return _stayAwakeDuringInference
        }
        set {
            withMutation(keyPath: \.stayAwakeDuringInference) {
                _stayAwakeDuringInference = newValue
            }
        }
    }
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
