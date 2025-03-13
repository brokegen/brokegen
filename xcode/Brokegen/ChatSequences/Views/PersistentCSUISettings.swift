import Combine
import SwiftUI


public let appStorageUpdateInterval = 3.0

/// @AppStorage needs a bit of manual plumbing to make it compatible with @Observable.
/// https://stackoverflow.com/questions/76606977/swift-ist-there-any-way-using-appstorage-with-observable
///
/// NB We're also implementing a (not-optimal) multi-step approach, where the extra variables are
/// a read-only cache that reads from system preferences once every second or so.
/// https://stackoverflow.com/questions/63678438/swiftui-updating-ui-with-high-frequency-data
///
@Observable
class PersistentDefaultCSUISettings: CSUISettings {
    @ObservationIgnored private var counter = PassthroughSubject<Int, Never>()
    @ObservationIgnored private var subscriber: AnyCancellable?

    private var isAppActive: Bool = true

    func startUpdater() {
        self.counter.send(-1)

        DispatchQueue.global(qos: .background)
            .asyncAfter(
                deadline: .now()
                + (isAppActive ? appStorageUpdateInterval : 60)
            ) {
                self.startUpdater()
            }
    }

    init() {
        NotificationCenter.default
            .addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                self.isAppActive = false
            }
        NotificationCenter.default
            .addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                self.isAppActive = true
            }

        subscriber = counter
            // Drop updates in the background
            .throttle(
                for: DispatchQueue.SchedulerTimeType.Stride(floatLiteral: appStorageUpdateInterval),
                scheduler: DispatchQueue.global(qos: .background),
                latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                self!.cached_allowContinuation = self!.live_allowContinuation
                self!.cached_showSeparateRetrievalButton = self!.live_showSeparateRetrievalButton
                self!.cached_forceRetrieval = self!.live_forceRetrieval

                self!.cached_showMessageHeaders = self!.live_showMessageHeaders
                self!.cached_renderAsMarkdown = self!.live_renderAsMarkdown
                self!.cached_messageFontDesign = self!.live_messageFontDesign
                self!.cached_messageFontSize = self!.live_messageFontSize
                self!.cached_textEntryFontDesign = self!.live_textEntryFontDesign

                self!.cached_responseBufferFlushFrequencyMsec = self!.live_responseBufferFlushFrequencyMsec
                self!.cached_scrollOnNewTextFrequencyMsec = self!.live_scrollOnNewTextFrequencyMsec
                self!.cached_animateResponseText = self!.live_animateResponseText

                self!.cached_showOFMPicker = self!.live_showOFMPicker
                self!.cached_stayAwakeDuringInference = self!.live_stayAwakeDuringInference
                self!.cached_promptEvalBatchSize = self!.live_promptEvalBatchSize
            }

        startUpdater()
    }

    // MARK: - @AppStorage caching, part 1
    @AppStorage("defaultUiSettings.allowContinuation")
    @ObservationIgnored private var stored_allowContinuation: Bool = true

    private var cached_allowContinuation: Bool? = nil

    @ObservationIgnored
    var live_allowContinuation: Bool {
        get {
            access(keyPath: \.live_allowContinuation)
            return stored_allowContinuation
        }
        set {
            withMutation(keyPath: \.live_allowContinuation) {
                stored_allowContinuation = newValue
                cached_allowContinuation = newValue
            }
        }
    }

    var allowContinuation: Bool {
        get { cached_allowContinuation ?? stored_allowContinuation }
        set { live_allowContinuation = newValue }
    }


    @AppStorage("defaultUiSettings.showSeparateRetrievalButton")
    @ObservationIgnored private var stored_showSeparateRetrievalButton: Bool = true

    private var cached_showSeparateRetrievalButton: Bool? = nil

    @ObservationIgnored
    var live_showSeparateRetrievalButton: Bool {
        get {
            access(keyPath: \.live_showSeparateRetrievalButton)
            return stored_showSeparateRetrievalButton
        }
        set {
            withMutation(keyPath: \.live_showSeparateRetrievalButton) {
                stored_showSeparateRetrievalButton = newValue
                cached_showSeparateRetrievalButton = newValue
            }
        }
    }

    var showSeparateRetrievalButton: Bool {
        get { cached_showSeparateRetrievalButton ?? stored_showSeparateRetrievalButton }
        set { live_showSeparateRetrievalButton = newValue }
    }


    @AppStorage("defaultUiSettings.forceRetrieval")
    @ObservationIgnored private var stored_forceRetrieval: Bool = false

    private var cached_forceRetrieval: Bool? = nil

    @ObservationIgnored
    var live_forceRetrieval: Bool {
        get {
            access(keyPath: \.live_forceRetrieval)
            return stored_forceRetrieval
        }
        set {
            withMutation(keyPath: \.live_forceRetrieval) {
                stored_forceRetrieval = newValue
                cached_forceRetrieval = newValue
            }
        }
    }

    var forceRetrieval: Bool {
        get { cached_forceRetrieval ?? stored_forceRetrieval }
        set { live_forceRetrieval = newValue }
    }


    // MARK: - @AppStorage caching, part 2
    @AppStorage("defaultUiSettings.showMessageHeaders")
    @ObservationIgnored private var stored_showMessageHeaders: Bool = false

    private var cached_showMessageHeaders: Bool? = nil

    @ObservationIgnored
    var live_showMessageHeaders: Bool {
        get {
            access(keyPath: \.live_showMessageHeaders)
            return stored_showMessageHeaders
        }
        set {
            withMutation(keyPath: \.live_showMessageHeaders) {
                stored_showMessageHeaders = newValue
                cached_showMessageHeaders = newValue
            }
        }
    }

    var showMessageHeaders: Bool {
        get { cached_showMessageHeaders ?? stored_showMessageHeaders }
        set { live_showMessageHeaders = newValue }
    }


    @AppStorage("defaultUiSettings.renderAsMarkdown")
    @ObservationIgnored private var stored_renderAsMarkdown: Bool = true

    private var cached_renderAsMarkdown: Bool? = nil

    @ObservationIgnored
    var live_renderAsMarkdown: Bool {
        get {
            access(keyPath: \.live_renderAsMarkdown)
            return stored_renderAsMarkdown
        }
        set {
            withMutation(keyPath: \.live_renderAsMarkdown) {
                stored_renderAsMarkdown = newValue
                cached_renderAsMarkdown = newValue
            }
        }
    }

    var renderAsMarkdown: Bool {
        get { cached_renderAsMarkdown ?? stored_renderAsMarkdown }
        set { live_renderAsMarkdown = newValue }
    }


    @AppStorage("defaultUiSettings.messageFontDesign")
    @ObservationIgnored private var stored_messageFontDesign: String = Font.Design.serif.toString()

    private var cached_messageFontDesign: String? = nil

    @ObservationIgnored
    var live_messageFontDesign: String {
        get {
            access(keyPath: \.live_messageFontDesign)
            return stored_messageFontDesign
        }
        set {
            withMutation(keyPath: \.live_messageFontDesign) {
                stored_messageFontDesign = newValue
                cached_messageFontDesign = newValue
            }
        }
    }

    var messageFontDesign: String {
        get { cached_messageFontDesign ?? stored_messageFontDesign }
        set { live_messageFontDesign = newValue }
    }


    @AppStorage("defaultUiSettings.messageFontSize")
    @ObservationIgnored private var stored_messageFontSize: Int = 18

    private var cached_messageFontSize: Int? = nil

    @ObservationIgnored
    var live_messageFontSize: Int {
        get {
            access(keyPath: \.live_messageFontSize)
            return stored_messageFontSize
        }
        set {
            withMutation(keyPath: \.live_messageFontSize) {
                stored_messageFontSize = newValue
                cached_messageFontSize = newValue
            }
        }
    }

    var messageFontSize: Int {
        get { cached_messageFontSize ?? stored_messageFontSize }
        set { live_messageFontSize = newValue }
    }


    @AppStorage("defaultUiSettings.textEntryFontDesign")
    @ObservationIgnored private var stored_textEntryFontDesign: String = "monospaced"

    private var cached_textEntryFontDesign: String? = nil

    @ObservationIgnored
    var live_textEntryFontDesign: String {
        get {
            access(keyPath: \.live_textEntryFontDesign)
            return stored_textEntryFontDesign
        }
        set {
            withMutation(keyPath: \.textEntryFontDesign) {
                stored_textEntryFontDesign = newValue
                cached_textEntryFontDesign = newValue
            }
        }
    }

    var textEntryFontDesign: String {
        get { cached_textEntryFontDesign ?? stored_textEntryFontDesign }
        set { live_textEntryFontDesign = newValue }
    }


    @AppStorage("defaultUiSettings.textEntryFontSize")
    @ObservationIgnored private var stored_textEntryFontSize: Int = 14

    private var cached_textEntryFontSize: Int? = nil

    @ObservationIgnored
    var live_textEntryFontSize: Int {
        get {
            access(keyPath: \.live_textEntryFontSize)
            return stored_textEntryFontSize
        }
        set {
            withMutation(keyPath: \.live_textEntryFontSize) {
                stored_textEntryFontSize = newValue
                cached_textEntryFontSize = newValue
            }
        }
    }

    var textEntryFontSize: Int {
        get { cached_textEntryFontSize ?? stored_textEntryFontSize }
        set { live_textEntryFontSize = newValue }
    }


    // MARK: - @AppStorage caching, part 3
    public static let default_responseBufferFlushFrequencyMsec: Int = 250

    @AppStorage("defaultUiSettings.responseBufferFlushFrequencyMsec")
    @ObservationIgnored private var stored_responseBufferFlushFrequencyMsec: Int = default_responseBufferFlushFrequencyMsec

    private var cached_responseBufferFlushFrequencyMsec: Int? = nil

    @ObservationIgnored
    var live_responseBufferFlushFrequencyMsec: Int {
        get {
            access(keyPath: \.live_responseBufferFlushFrequencyMsec)
            return stored_responseBufferFlushFrequencyMsec
        }
        set {
            withMutation(keyPath: \.live_responseBufferFlushFrequencyMsec) {
                stored_responseBufferFlushFrequencyMsec = newValue
                cached_responseBufferFlushFrequencyMsec = newValue
            }
        }
    }

    var responseBufferFlushFrequencyMsec: Int {
        get { cached_responseBufferFlushFrequencyMsec ?? stored_responseBufferFlushFrequencyMsec }
        set { live_responseBufferFlushFrequencyMsec = newValue }
    }


    public static let default_scrollOnNewTextFrequencyMsec: Int = 600

    @AppStorage("defaultUiSettings.scrollOnNewTextFrequencyMsec")
    @ObservationIgnored private var stored_scrollOnNewTextFrequencyMsec: Int = default_scrollOnNewTextFrequencyMsec

    private var cached_scrollOnNewTextFrequencyMsec: Int? = nil

    @ObservationIgnored
    var live_scrollOnNewTextFrequencyMsec: Int {
        get {
            access(keyPath: \.live_scrollOnNewTextFrequencyMsec)
            return stored_scrollOnNewTextFrequencyMsec
        }
        set {
            withMutation(keyPath: \.live_scrollOnNewTextFrequencyMsec) {
                stored_scrollOnNewTextFrequencyMsec = newValue
                cached_scrollOnNewTextFrequencyMsec = newValue
            }
        }
    }

    var scrollOnNewTextFrequencyMsec: Int {
        get { cached_scrollOnNewTextFrequencyMsec ?? stored_scrollOnNewTextFrequencyMsec }
        set { live_scrollOnNewTextFrequencyMsec = newValue }
    }


    @AppStorage("defaultUiSettings.animateResponseText")
    @ObservationIgnored private var stored_animateResponseText: String = AnimateText.plaintextOnly.toString()

    private var cached_animateResponseText: String? = nil

    @ObservationIgnored
    var live_animateResponseText: String {
        get {
            access(keyPath: \.live_animateResponseText)
            return stored_animateResponseText
        }
        set {
            withMutation(keyPath: \.live_animateResponseText) {
                stored_animateResponseText = newValue
                cached_animateResponseText = newValue
            }
        }
    }

    var animateResponseText: String {
        get { cached_animateResponseText ?? stored_animateResponseText }
        set { live_animateResponseText = newValue }
    }


    // MARK: - @AppStorage caching, part 4
    @AppStorage("defaultUiSettings.showOFMPicker")
    @ObservationIgnored private var stored_showOFMPicker: Bool = false

    private var cached_showOFMPicker: Bool? = nil

    @ObservationIgnored
    var live_showOFMPicker: Bool {
        get {
            access(keyPath: \.live_showOFMPicker)
            return stored_showOFMPicker
        }
        set {
            withMutation(keyPath: \.live_showOFMPicker) {
                stored_showOFMPicker = newValue
                cached_showOFMPicker = newValue
            }
        }
    }

    var showOFMPicker: Bool {
        get { cached_showOFMPicker ?? stored_showOFMPicker }
        set { live_showOFMPicker = newValue }
    }


    @AppStorage("defaultUiSettings.stayAwakeDuringInference")
    @ObservationIgnored private var stored_stayAwakeDuringInference: Bool = true

    private var cached_stayAwakeDuringInference: Bool? = nil

    @ObservationIgnored
    var live_stayAwakeDuringInference: Bool {
        get {
            access(keyPath: \.live_stayAwakeDuringInference)
            return stored_stayAwakeDuringInference
        }
        set {
            withMutation(keyPath: \.live_stayAwakeDuringInference) {
                stored_stayAwakeDuringInference = newValue
                cached_stayAwakeDuringInference = newValue
            }
        }
    }

    var stayAwakeDuringInference: Bool {
        get { cached_stayAwakeDuringInference ?? stored_stayAwakeDuringInference }
        set { live_stayAwakeDuringInference = newValue }
    }


    @AppStorage("serverInferenceSettings.promptEvalBatchSize")
    @ObservationIgnored private var stored_promptEvalBatchSize: Int = 0

    private var cached_promptEvalBatchSize: Int? = nil

    @ObservationIgnored
    var live_promptEvalBatchSize: Int {
        get {
            access(keyPath: \.live_promptEvalBatchSize)
            return stored_promptEvalBatchSize
        }
        set {
            withMutation(keyPath: \.live_promptEvalBatchSize) {
                stored_promptEvalBatchSize = newValue
                cached_promptEvalBatchSize = newValue
            }
        }
    }

    var promptEvalBatchSize: Int {
        get { cached_promptEvalBatchSize ?? stored_promptEvalBatchSize }
        set { live_promptEvalBatchSize = newValue }
    }
}
