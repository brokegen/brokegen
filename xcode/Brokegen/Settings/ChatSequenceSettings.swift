import SwiftUI

enum ChatAutoNaming: String {
    case serverDefault, disable, summarizeAfterAsync, summarizeBefore
}

/// NB Most of these currently do not work.
@Observable
class GlobalChatSequenceClientSettings {
    var inferenceOptions: String = ""
    var overrideSystemPrompt: String = ""

    var retrieverOptions: String = ""
    var chatAutoNaming: ChatAutoNaming = .serverDefault

    // UI options
    // @AppStorage("allowContinuation")
    var allowContinuation: Bool = true
    var showSeparateRetrievalButton: Bool = true
    var forceRetrieval: Bool = false

    var allowNewlineSubmit: Bool = true
    var stayAwakeDuringInference: Bool = true
}

@Observable
class ChatSequenceClientSettings {
    var inferenceOptions: String? = nil
    var overrideSystemPrompt: String? = nil

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
