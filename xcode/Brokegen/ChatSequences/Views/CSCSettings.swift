protocol CSUISettings {
    // MARK: - UI Behaviors
    var allowContinuation: Bool { get set }
    var showSeparateRetrievalButton: Bool { get set }
    var forceRetrieval: Bool { get set }

    // MARK: - UI Appearance
    var showMessageHeaders: Bool { get set }
    var renderAsMarkdown: Bool { get set }
    /// NB This is the stringified name for a Font.Design
    var messageFontDesign: String { get set }
    var messageFontSize: Int { get set }
    /// NB This is the stringified name for a Font.Design
    var textEntryFontDesign: String { get set }
    var textEntryFontSize: Int { get set }

    // MARK: - UI Performance tweaks
    var responseBufferFlushFrequencyMsec: Int { get set }
    /// NB Value of 0 means scrolling is immediate, values less than 0 mean disabled.
    var scrollOnNewTextFrequencyMsec: Int { get set }
    var animateNewResponseText: Bool { get set }

    // MARK: - misc
    var showOFMPicker: Bool { get set }
    var stayAwakeDuringInference: Bool { get set }
    var promptEvalBatchSize: Int { get set }
}

// TODO: Does this need to conform to @Observable?
// Can it actually be used in its stead?
struct InMemoryCSUISettings: CSUISettings {
    var allowContinuation: Bool
    var showSeparateRetrievalButton: Bool
    var forceRetrieval: Bool
    
    var showMessageHeaders: Bool
    var renderAsMarkdown: Bool
    var messageFontDesign: String
    var messageFontSize: Int
    var textEntryFontDesign: String
    var textEntryFontSize: Int

    var responseBufferFlushFrequencyMsec: Int
    var scrollOnNewTextFrequencyMsec: Int
    var animateNewResponseText: Bool

    var showOFMPicker: Bool
    var stayAwakeDuringInference: Bool
    var promptEvalBatchSize: Int
}

struct OverrideCSUISettings {
    var allowContinuation: Bool? = nil
    var showSeparateRetrievalButton: Bool? = nil
    var forceRetrieval: Bool? = nil

    var pinChatSequenceDesc: Bool? = nil
    var showMessageHeaders: Bool? = nil
    var renderAsMarkdown: Bool? = nil

    var showOFMPicker: Bool? = nil
    var stayAwakeDuringInference: Bool? = nil
}

struct CSInferenceSettings {
    enum AutonamingPolicy: String, CaseIterable, Identifiable {
        case serverDefault, disable, summarizeAfterAsync, summarizeBefore

        func asUiLabel() -> String {
            switch(self) {
            case .serverDefault:
                "server default"
            case .disable:
                "disable"
            case .summarizeAfterAsync:
                "summarize after inference (asynchronous)"
            case .summarizeBefore:
                "summarize before inference"
            }
        }

        var id: String {
            self.rawValue
        }
    }

    enum RetrievalPolicy: String, CaseIterable, Identifiable {
        case skip, simple, simpleAll, summarizing

        func asUiLabel() -> String {
            self.id
        }

        var id: String {
            switch(self) {
            case .simpleAll:
                "simple-all"
            default:
                self.rawValue
            }
        }
    }

    var inferenceOptions: String? = nil
    var overrideModelTemplate: String? = nil
    var overrideSystemPrompt: String? = nil
    var seedAssistantResponse: String? = nil

    var retrievalPolicy: RetrievalPolicy = .simple
    var retrievalSearchArgs: String? = nil

    var autonamingPolicy: AutonamingPolicy = .serverDefault
}
