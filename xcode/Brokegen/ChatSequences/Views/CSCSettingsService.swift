import SwiftUI

@Observable
class CSCSettingsService {
    @AppStorage("useSimplifiedBlankOSV")
    @ObservationIgnored public var _useSimplifiedBlankOSV: Bool = true

    @ObservationIgnored
    var useSimplifiedBlankOSV: Bool {
        get {
            access(keyPath: \.useSimplifiedBlankOSV)
            return _useSimplifiedBlankOSV
        }
        set {
            withMutation(keyPath: \.useSimplifiedBlankOSV) {
                _useSimplifiedBlankOSV = newValue
            }
        }
    }

    @AppStorage("useSimplifiedOSV")
    @ObservationIgnored public var _useSimplifiedOSV: Bool = true

    @ObservationIgnored
    var useSimplifiedOSV: Bool {
        get {
            access(keyPath: \.useSimplifiedOSV)
            return _useSimplifiedOSV
        }
        set {
            withMutation(keyPath: \.useSimplifiedOSV) {
                _useSimplifiedOSV = newValue
            }
        }
    }

    let defaults: CSUISettings = PersistentDefaultCSUISettings()
    var perSequenceUiSettings: [ChatSequenceServerID : OverrideCSUISettings] = [:]
    var perSequenceInferenceSettings: [ChatSequenceServerID : CSInferenceSettings] = [:]

    @Observable
    class SettingsProxy {
        var defaults: CSUISettings
        var override: OverrideCSUISettings
        var inference: CSInferenceSettings

        init(defaults: CSUISettings, override: OverrideCSUISettings, inference: CSInferenceSettings) {
            self.defaults = defaults
            self.override = override
            self.inference = inference
        }

        // MARK: - OverrideCSUISettings
        var allowContinuation: Bool {
            get { override.allowContinuation ?? defaults.allowContinuation }
            set { override.allowContinuation = newValue }
        }

        var showSeparateRetrievalButton: Bool {
            get { override.showSeparateRetrievalButton ?? defaults.showSeparateRetrievalButton }
            set { override.showSeparateRetrievalButton = newValue }
        }

        var forceRetrieval: Bool {
            get { override.forceRetrieval ?? defaults.forceRetrieval }
            set { override.forceRetrieval = newValue }
        }

        var pinChatSequenceDesc: Bool {
            get { override.pinChatSequenceDesc ?? false }
            set { override.pinChatSequenceDesc = newValue }
        }

        var showMessageHeaders: Bool {
            get { override.showMessageHeaders ?? defaults.showMessageHeaders }
            set { override.showMessageHeaders = newValue }
        }

        var renderAsMarkdown: Bool {
            get { override.renderAsMarkdown ?? defaults.renderAsMarkdown }
            set { override.renderAsMarkdown = newValue }
        }

        var messageFontDesign: Font.Design {
            get { Font.Design.fromString(defaults.messageFontDesign) }
            set {
                defaults.messageFontDesign = newValue.toString()
            }
        }

        var messageFontSize: CGFloat {
            get { CGFloat(defaults.messageFontSize) }
            set {
                defaults.messageFontSize = Int(newValue)
            }
        }

        var textEntryFontDesign: Font.Design {
            get { Font.Design.fromString(defaults.textEntryFontDesign) }
            set {
                defaults.textEntryFontDesign = newValue.toString()
            }
        }

        var textEntryFontSize: CGFloat {
            get { CGFloat(defaults.textEntryFontSize) }
            set {
                defaults.textEntryFontSize = Int(newValue)
            }
        }

        var responseBufferFlushFrequencyMsec: Int {
            get { defaults.responseBufferFlushFrequencyMsec }
            set { defaults.responseBufferFlushFrequencyMsec = newValue }
        }

        var responseBufferFlush: Bool {
            get { defaults.responseBufferFlushFrequencyMsec > 0 }
            set {
                defaults.responseBufferFlushFrequencyMsec = newValue
                ? PersistentDefaultCSUISettings.default_responseBufferFlushFrequencyMsec
                : 0
            }
        }

        var scrollOnNewTextFrequencyMsec: Int {
            get { defaults.scrollOnNewTextFrequencyMsec }
            set { defaults.scrollOnNewTextFrequencyMsec = newValue }
        }

        var scrollOnNewText: Bool {
            get { defaults.scrollOnNewTextFrequencyMsec >= 0 }
            set {
                defaults.scrollOnNewTextFrequencyMsec = newValue
                ? PersistentDefaultCSUISettings.default_scrollOnNewTextFrequencyMsec
                : -1
            }
        }

        var animateResponseText: AnimateText {
            get { AnimateText.fromString(defaults.animateResponseText) }
            set {
                defaults.animateResponseText = newValue.toString()
            }
        }

        var animateResponseTextSimple: Bool {
            get { AnimateText.fromString(defaults.animateResponseText) != .never }
            set {
                defaults.animateResponseText = newValue
                ? AnimateText.plaintextOnly.toString()
                : AnimateText.never.toString()
            }
        }

        var showOFMPicker: Bool {
            get { override.showOFMPicker ?? defaults.showOFMPicker }
            set { override.showOFMPicker = newValue }
        }

        var stayAwakeDuringInference: Bool {
            get { override.stayAwakeDuringInference ?? defaults.stayAwakeDuringInference }
            set { override.stayAwakeDuringInference = newValue }
        }

        // MARK: - CSInferenceSettings
        var inferenceOptions: String {
            get { inference.inferenceOptions ?? "" }
            set { inference.inferenceOptions = newValue }
        }

        var promptEvalBatchSize: Int {
            get { defaults.promptEvalBatchSize }
            set { defaults.promptEvalBatchSize = newValue }
        }

        var overrideModelTemplate: String {
            get { inference.overrideModelTemplate ?? "" }
            set { inference.overrideModelTemplate = newValue }
        }

        var overrideSystemPrompt: String {
            get { inference.overrideSystemPrompt ?? "" }
            set { inference.overrideSystemPrompt = newValue }
        }

        var seedAssistantResponse: String {
            get { inference.seedAssistantResponse ?? "" }
            set { inference.seedAssistantResponse = newValue }
        }

        var retrievalPolicy: CSInferenceSettings.RetrievalPolicy {
            get { inference.retrievalPolicy }
            set { inference.retrievalPolicy = newValue }
        }

        var retrievalSearchArgs: String {
            get { inference.retrievalSearchArgs ?? "" }
            set { inference.retrievalSearchArgs = newValue }
        }

        var autonamingPolicy: CSInferenceSettings.AutonamingPolicy {
            get { inference.autonamingPolicy }
            set { inference.autonamingPolicy = newValue }
        }
    }

    public func settings(for sequenceId: ChatSequenceServerID) -> SettingsProxy {
        var uiSettings = perSequenceUiSettings[sequenceId]
        if uiSettings == nil {
            uiSettings = OverrideCSUISettings()
            perSequenceUiSettings[sequenceId] = uiSettings
        }

        var inferenceSettings = perSequenceInferenceSettings[sequenceId]
        if inferenceSettings == nil {
            inferenceSettings = CSInferenceSettings()
            perSequenceInferenceSettings[sequenceId] = inferenceSettings
        }

        return SettingsProxy(defaults: self.defaults, override: uiSettings!, inference: inferenceSettings!)
    }

    public func registerSettings(_ settings: SettingsProxy, for sequenceId: ChatSequenceServerID) {
        perSequenceUiSettings[sequenceId] = settings.override
        perSequenceInferenceSettings[sequenceId] = settings.inference
    }
}

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
            String(describing: self)
        }
    }
}

extension Font.Design: CaseIterable {
    public static var allCases: [Font.Design] {
        return [.serif, .rounded, .monospaced, .default]
    }
}

extension Font.Design: Identifiable {
    public var id: String {
        return self.toString()
    }
}
