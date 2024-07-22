import Combine
import SwiftUI

/// @AppStorage needs a bit of manual plumbing to make it compatible with @Observable.
/// https://stackoverflow.com/questions/76606977/swift-ist-there-any-way-using-appstorage-with-observable
///
@Observable
class PersistentDefaultCSUISettings {
    public var cached_showMessageHeaders: Bool = false
    public var cached_renderAsMarkdown: Bool = false
    public var cached_messageFontDesign: String = ""

    @ObservationIgnored private var counter = PassthroughSubject<Int, Never>()
    @ObservationIgnored private var subscriber: AnyCancellable?

    func startUpdater() {
        self.counter.send(-1)

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.3) {
            self.startUpdater()
        }
    }

    init() {
        // https://stackoverflow.com/questions/63678438/swiftui-updating-ui-with-high-frequency-data
        subscriber = counter
            // Drop updates in the background
            .throttle(for: 1.1, scheduler: DispatchQueue.global(qos: .background), latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                self!.cached_showMessageHeaders = self!.showMessageHeaders
                self!.cached_renderAsMarkdown = self!.renderAsMarkdown
                self!.cached_messageFontDesign = self!.messageFontDesign
            }

        startUpdater()
    }

    @AppStorage("defaultUiSettings.allowContinuation")
    @ObservationIgnored private var stored_allowContinuation: Bool = true

    @ObservationIgnored
    var allowContinuation: Bool {
        get {
            access(keyPath: \.allowContinuation)
            return stored_allowContinuation
        }
        set {
            withMutation(keyPath: \.allowContinuation) {
                stored_allowContinuation = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.showSeparateRetrievalButton")
    @ObservationIgnored private var stored_showSeparateRetrievalButton: Bool = true

    @ObservationIgnored
    var showSeparateRetrievalButton: Bool {
        get {
            access(keyPath: \.showSeparateRetrievalButton)
            return stored_showSeparateRetrievalButton
        }
        set {
            withMutation(keyPath: \.showSeparateRetrievalButton) {
                stored_showSeparateRetrievalButton = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.forceRetrieval")
    @ObservationIgnored private var stored_forceRetrieval: Bool = false

    @ObservationIgnored
    var forceRetrieval: Bool {
        get {
            access(keyPath: \.forceRetrieval)
            return stored_forceRetrieval
        }
        set {
            withMutation(keyPath: \.forceRetrieval) {
                stored_forceRetrieval = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.showMessageHeaders")
    @ObservationIgnored private var stored_showMessageHeaders: Bool = false

    @ObservationIgnored
    var showMessageHeaders: Bool {
        get {
            access(keyPath: \.showMessageHeaders)
            return stored_showMessageHeaders
        }
        set {
            withMutation(keyPath: \.showMessageHeaders) {
                stored_showMessageHeaders = newValue
                cached_showMessageHeaders = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.renderAsMarkdown")
    @ObservationIgnored private var stored_renderAsMarkdown: Bool = true

    @ObservationIgnored
    var renderAsMarkdown: Bool {
        get {
            access(keyPath: \.renderAsMarkdown)
            return stored_renderAsMarkdown
        }
        set {
            withMutation(keyPath: \.renderAsMarkdown) {
                stored_renderAsMarkdown = newValue
                cached_renderAsMarkdown = newValue
            }
        }
    }

    // NB This is the stringified name for a Font.Design
    @AppStorage("defaultUiSettings.messageFontDesign")
    @ObservationIgnored private var stored_messageFontDesign: String = ""

    @ObservationIgnored
    var messageFontDesign: String {
        get {
            access(keyPath: \.messageFontDesign)
            return stored_messageFontDesign
        }
        set {
            withMutation(keyPath: \.messageFontDesign) {
                stored_messageFontDesign = newValue
                cached_messageFontDesign = newValue
            }
        }
    }

    // NB This is the stringified name for a Font.Design
    @AppStorage("defaultUiSettings.textEntryFontDesign")
    @ObservationIgnored private var stored_textEntryFontDesign: String = ""

    @ObservationIgnored
    var textEntryFontDesign: String {
        get {
            access(keyPath: \.textEntryFontDesign)
            return stored_textEntryFontDesign
        }
        set {
            withMutation(keyPath: \.textEntryFontDesign) {
                stored_textEntryFontDesign = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.responseBufferFlushFrequencyMsec")
    @ObservationIgnored private var stored_responseBufferFlushFrequencyMsec: Int = 250

    @ObservationIgnored
    var responseBufferFlushFrequencyMsec: Int {
        get {
            access(keyPath: \.responseBufferFlushFrequencyMsec)
            return stored_responseBufferFlushFrequencyMsec
        }
        set {
            withMutation(keyPath: \.responseBufferFlushFrequencyMsec) {
                stored_responseBufferFlushFrequencyMsec = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.scrollToBottomOnNew")
    @ObservationIgnored private var stored_scrollToBottomOnNew: Bool = true

    @ObservationIgnored
    var scrollToBottomOnNew: Bool {
        get {
            access(keyPath: \.scrollToBottomOnNew)
            return stored_scrollToBottomOnNew
        }
        set {
            withMutation(keyPath: \.scrollToBottomOnNew) {
                stored_scrollToBottomOnNew = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.animateNewResponseText")
    @ObservationIgnored private var stored_animateNewResponseText: Bool = true

    @ObservationIgnored
    var animateNewResponseText: Bool {
        get {
            access(keyPath: \.animateNewResponseText)
            return stored_animateNewResponseText
        }
        set {
            withMutation(keyPath: \.animateNewResponseText) {
                stored_animateNewResponseText = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.showOFMPicker")
    @ObservationIgnored private var stored_showOFMPicker: Bool = false

    @ObservationIgnored
    var showOFMPicker: Bool {
        get {
            access(keyPath: \.showOFMPicker)
            return stored_showOFMPicker
        }
        set {
            withMutation(keyPath: \.showOFMPicker) {
                stored_showOFMPicker = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.stayAwakeDuringInference")
    @ObservationIgnored private var stored_stayAwakeDuringInference: Bool = true

    @ObservationIgnored
    var stayAwakeDuringInference: Bool {
        get {
            access(keyPath: \.stayAwakeDuringInference)
            return stored_stayAwakeDuringInference
        }
        set {
            withMutation(keyPath: \.stayAwakeDuringInference) {
                stored_stayAwakeDuringInference = newValue
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

    var showOFMPicker: Bool? = nil
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
