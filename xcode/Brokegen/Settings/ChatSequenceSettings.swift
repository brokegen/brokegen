import SwiftUI

enum ChatAutoNaming: String {
    case serverDefault, disable, summarizeAfterAsync, summarizeBefore
}

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
    var allowNewlineSubmit: Bool = false
}

struct ChatSequenceClientSettings {
    var allowContinuation: Bool? = nil
    var showSeparateRetrievalButton: Bool? = nil
    var forceRetrieval: Bool? = nil
    var allowNewlineSubmit: Bool? = nil
}
