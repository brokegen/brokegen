import Combine
import SwiftUI

/// @AppStorage needs a bit of manual plumbing to make it compatible with @Observable.
/// https://stackoverflow.com/questions/76606977/swift-ist-there-any-way-using-appstorage-with-observable
///
@Observable
class PersistentDefaultCSUISettings: CSUISettings {
    public var cached_showMessageHeaders: Bool = false
    public var cached_renderAsMarkdown: Bool = false
    public var cached_messageFontDesign: String = ""
    public static let default_messageFontSize: Int = 18
    public var cached_messageFontSize: Int = default_messageFontSize

    public static let default_responseBufferFlushFrequencyMsec: Int = 250
    public var cached_responseBufferFlushFrequencyMsec: Int = default_responseBufferFlushFrequencyMsec
    public static let default_scrollOnNewTextFrequencyMsec: Int = 600
    public var cached_scrollOnNewTextFrequencyMsec: Int = default_scrollOnNewTextFrequencyMsec
    public var cached_animateNewResponseText: Bool = false

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
        //
        // NB We're implementing a (not-optimal) multi-step approach, where
        // the extra variables are a read-only cache that reads from system preferences once every second or so.
        //
        subscriber = counter
            // Drop updates in the background
            .throttle(for: 1.1, scheduler: DispatchQueue.global(qos: .background), latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                self!.cached_showMessageHeaders = self!.showMessageHeaders
                self!.cached_renderAsMarkdown = self!.renderAsMarkdown
                self!.cached_messageFontDesign = self!.messageFontDesign

                self!.cached_responseBufferFlushFrequencyMsec = self!.responseBufferFlushFrequencyMsec
                self!.cached_scrollOnNewTextFrequencyMsec = self!.scrollOnNewTextFrequencyMsec
                self!.cached_animateNewResponseText = self!.animateNewResponseText
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

    @AppStorage("defaultUiSettings.messageFontSize")
    @ObservationIgnored private var stored_messageFontSize: Int = default_messageFontSize

    @ObservationIgnored
    var messageFontSize: Int {
        get {
            access(keyPath: \.messageFontSize)
            return stored_messageFontSize
        }
        set {
            withMutation(keyPath: \.messageFontSize) {
                stored_messageFontSize = newValue
                cached_messageFontSize = newValue
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
    @ObservationIgnored private var stored_responseBufferFlushFrequencyMsec: Int = default_responseBufferFlushFrequencyMsec

    @ObservationIgnored
    var responseBufferFlushFrequencyMsec: Int {
        get {
            access(keyPath: \.responseBufferFlushFrequencyMsec)
            return stored_responseBufferFlushFrequencyMsec
        }
        set {
            withMutation(keyPath: \.responseBufferFlushFrequencyMsec) {
                stored_responseBufferFlushFrequencyMsec = newValue
                cached_responseBufferFlushFrequencyMsec = newValue
            }
        }
    }

    @AppStorage("defaultUiSettings.scrollOnNewTextFrequencyMsec")
    @ObservationIgnored private var stored_scrollOnNewTextFrequencyMsec: Int = default_scrollOnNewTextFrequencyMsec

    /// NB Value of 0 means scrolling is immediate, values less than 0 mean disabled.
    @ObservationIgnored
    var scrollOnNewTextFrequencyMsec: Int {
        get {
            access(keyPath: \.scrollOnNewTextFrequencyMsec)
            return stored_scrollOnNewTextFrequencyMsec
        }
        set {
            withMutation(keyPath: \.scrollOnNewTextFrequencyMsec) {
                stored_scrollOnNewTextFrequencyMsec = newValue
                cached_scrollOnNewTextFrequencyMsec = newValue
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
                cached_animateNewResponseText = newValue
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
