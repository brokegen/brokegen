import SwiftUI

@Observable
class CSCSettingsService: ObservableObject {
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

    let defaults: PersistentDefaultCSUISettings = PersistentDefaultCSUISettings()
    var perSequenceUiSettings: [ChatSequenceServerID : OverrideCSUISettings] = [:]
    var perSequenceInferenceSettings: [ChatSequenceServerID : CSInferenceSettings] = [:]

    @Observable
    class SettingsProxy: ObservableObject {
        var defaults: PersistentDefaultCSUISettings
        var override: OverrideCSUISettings
        var inference: CSInferenceSettings

        init(defaults: PersistentDefaultCSUISettings, override: OverrideCSUISettings, inference: CSInferenceSettings) {
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
            get { override.showMessageHeaders ?? defaults.cached_showMessageHeaders }
            set { override.showMessageHeaders = newValue }
        }

        var renderAsMarkdown: Bool {
            get { override.renderAsMarkdown ?? defaults.cached_renderAsMarkdown }
            set { override.renderAsMarkdown = newValue }
        }

        var messageFontDesign: Font.Design {
            get { Font.Design.fromString(defaults.cached_messageFontDesign) }
            set {
                defaults.messageFontDesign = newValue.toString()
                objectWillChange.send()
            }
        }

        var textEntryFontDesign: Font.Design {
            get { Font.Design.fromString(defaults.textEntryFontDesign) }
            set {
                defaults.textEntryFontDesign = newValue.toString()
                objectWillChange.send()
            }
        }

        var scrollToBottomOnNew: Bool {
            get { override.scrollToBottomOnNew ?? defaults.scrollToBottomOnNew }
            set { override.scrollToBottomOnNew = newValue }
        }

        var animateNewResponseText: Bool {
            get { override.animateNewResponseText ?? defaults.animateNewResponseText }
            set { override.animateNewResponseText = newValue }
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

        var retrievalPolicy: String {
            get { inference.retrievalPolicy ?? "" }
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
            ""
        }
    }
}
