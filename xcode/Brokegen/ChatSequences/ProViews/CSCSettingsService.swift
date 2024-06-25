import SwiftUI

@Observable
class CSCSettingsService: Observable, ObservableObject {
    @AppStorage("useSimplifiedBlankOSV")
    @ObservationIgnored public var useSimplifiedBlankOSV: Bool = true

    @AppStorage("useSimplifiedSequenceViews")
    @ObservationIgnored public var useSimplifiedSequenceViews: Bool = true

    @ObservationIgnored let defaults: PersistentDefaultCSUISettings = PersistentDefaultCSUISettings()
    var perSequenceUiSettings: [ChatSequence : OverrideCSUISettings] = [:]
    var perSequenceInferenceSettings: [ChatSequence : CSInferenceSettings] = [:]

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
            get { override.showMessageHeaders ?? defaults.showMessageHeaders }
            set { override.showMessageHeaders = newValue }
        }

        var scrollToBottomOnNew: Bool {
            get { override.scrollToBottomOnNew ?? defaults.scrollToBottomOnNew }
            set { override.scrollToBottomOnNew = newValue }
        }

        var showOIMPicker: Bool {
            get { override.showOIMPicker ?? defaults.showOIMPicker }
            set { override.showOIMPicker = newValue }
        }

        var allowNewlineSubmit: Bool {
            get { override.allowNewlineSubmit ?? defaults.allowNewlineSubmit }
            set { override.allowNewlineSubmit = newValue }
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

    public func settings(for sequence: ChatSequence) -> SettingsProxy {
        var uiSettings = perSequenceUiSettings[sequence]
        if uiSettings == nil {
            uiSettings = OverrideCSUISettings()
            perSequenceUiSettings[sequence] = uiSettings
        }

        var inferenceSettings = perSequenceInferenceSettings[sequence]
        if inferenceSettings == nil {
            inferenceSettings = CSInferenceSettings()
            perSequenceInferenceSettings[sequence] = inferenceSettings
        }

        return SettingsProxy(defaults: defaults, override: uiSettings!, inference: inferenceSettings!)
    }
}
