import SwiftUI

@Observable
class CSCSettingsService: Observable, ObservableObject {
    // Legacy, should be removed
    @ObservationIgnored public var sequenceSettings: GlobalChatSequenceClientSettings = GlobalChatSequenceClientSettings()

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

        var chatAutoNaming: ChatAutoNaming {
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

/// NB Most of these currently do not work.
@Observable
class GlobalChatSequenceClientSettings {
    var inferenceOptions: String = ""
    var overrideSystemPrompt: String = ""
    var seedAssistantResponse: String = ""

    var retrieverOptions: String = ""
    var chatAutoNaming: ChatAutoNaming = .serverDefault

    // Local, UI-specific options
    var allowContinuation: Bool = true
    var showSeparateRetrievalButton: Bool = true
    var forceRetrieval: Bool = false

    var allowNewlineSubmit: Bool = false
    var stayAwakeDuringInference: Bool = true
}

@Observable
class ChatSequenceClientSettings {
    var inferenceOptions: String? = nil
    var overrideSystemPrompt: String? = nil
    var seedAssistantResponse: String? = nil

    var retrieverOptions: String? = nil
    var chatAutoNaming: ChatAutoNaming? = nil

    var allowContinuation: Bool? = nil
    var showSeparateRetrievalButton: Bool? = nil
    var forceRetrieval: Bool? = nil

    var allowNewlineSubmit: Bool? = nil
    var stayAwakeDuringInference: Bool? = nil
}

@Observable
class CombinedCSCSettings {
    let globalSettings: GlobalChatSequenceClientSettings
    let sequenceSettings: ChatSequenceClientSettings

    init(globalSettings: GlobalChatSequenceClientSettings, sequenceSettings: ChatSequenceClientSettings) {
        self.globalSettings = globalSettings
        self.sequenceSettings = sequenceSettings
    }

    func inferenceOptions(overrideGlobal: Bool? = nil) -> Binding<String> {
        return Binding(
            get: { self.sequenceSettings.inferenceOptions ?? self.globalSettings.inferenceOptions },
            set: { value in
                if overrideGlobal != nil && overrideGlobal! {
                    self.globalSettings.inferenceOptions = value
                }
                else {
                    self.sequenceSettings.inferenceOptions = value
                }
            })
    }

    func overrideSystemPrompt(overrideGlobal: Bool? = nil) -> Binding<String> {
        return Binding(
            get: { self.sequenceSettings.overrideSystemPrompt ?? self.globalSettings.overrideSystemPrompt },
            set: { value in
                if overrideGlobal != nil && overrideGlobal! {
                    self.globalSettings.overrideSystemPrompt = value
                }
                else {
                    self.sequenceSettings.overrideSystemPrompt = value
                }
            })
    }

    func seedAssistantResponse(overrideGlobal: Bool? = nil) -> Binding<String> {
        return Binding(
            get: { self.sequenceSettings.seedAssistantResponse ?? self.globalSettings.seedAssistantResponse },
            set: { value in
                if overrideGlobal != nil && overrideGlobal! {
                    self.globalSettings.seedAssistantResponse = value
                }
                else {
                    self.sequenceSettings.seedAssistantResponse = value
                }
            })
    }

    func retrieverOptions(overrideGlobal: Bool? = nil) -> Binding<String> {
        return Binding(
            get: { self.sequenceSettings.retrieverOptions ?? self.globalSettings.retrieverOptions },
            set: { value in
                if overrideGlobal != nil && overrideGlobal! {
                    self.globalSettings.retrieverOptions = value
                }
                else {
                    self.sequenceSettings.retrieverOptions = value
                }
            })
    }

    var allowContinuation: Bool {
        get { sequenceSettings.allowContinuation ?? globalSettings.allowContinuation }
        set { print("[WARNING] Trying to set CombinedCSCSettings.allowContinuation, ignoring") }
    }

    var showSeparateRetrievalButton: Bool {
        get { sequenceSettings.showSeparateRetrievalButton ?? globalSettings.showSeparateRetrievalButton }
        set { print("[WARNING] Trying to set CombinedCSCSettings.showSeparateRetrievalButton, ignoring") }
    }

    var forceRetrieval: Bool {
        get { sequenceSettings.forceRetrieval ?? globalSettings.forceRetrieval }
        set { print("[WARNING] Trying to set CombinedCSCSettings.forceRetrieval, ignoring") }
    }

    var allowNewlineSubmit: Bool {
        get { sequenceSettings.allowNewlineSubmit ?? globalSettings.allowNewlineSubmit }
        set { print("[WARNING] Trying to set CombinedCSCSettings.allowNewlineSubmit, ignoring") }
    }
}
