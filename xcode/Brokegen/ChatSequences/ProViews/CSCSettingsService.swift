import SwiftUI

@Observable
class CSCSettingsService: Observable, ObservableObject {
    @AppStorage("useSimplifiedSequenceViews")
    @ObservationIgnored public var useSimplifiedSequenceViews: Bool = false

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

        var allowNewlineSubmit: Bool {
            get { override.allowNewlineSubmit ?? defaults.allowNewlineSubmit }
            set { override.allowNewlineSubmit = newValue }
        }

        var stayAwakeDuringInference: Bool {
            get { override.stayAwakeDuringInference ?? defaults.stayAwakeDuringInference }
            set { override.stayAwakeDuringInference = newValue }
        }

        var inferenceOptions: String {
            get { inference.inferenceOptions ?? "" }
            set { inference.inferenceOptions = newValue }
        }

        var overrideSystemPrompt: String {
            get { inference.overrideSystemPrompt ?? "" }
            set { inference.overrideSystemPrompt = newValue }
        }

        var seedAssistantResponse: String {
            get { inference.seedAssistantResponse ?? "" }
            set { inference.seedAssistantResponse = newValue }
        }

        var retrieverOptions: String {
            get { inference.retrieverOptions ?? "" }
            set { inference.retrieverOptions = newValue }
        }

        var chatAutoNaming: CSInferenceSettings.ChatAutoNaming {
            get { inference.chatAutoNaming }
            set { inference.chatAutoNaming = newValue }
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
