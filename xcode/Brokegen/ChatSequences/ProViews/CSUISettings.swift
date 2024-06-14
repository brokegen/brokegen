import SwiftUI

struct DefaultCSUISettings {
    var allowContinuation: Bool = true
    var showSeparateRetrievalButton: Bool = true
    var forceRetrieval: Bool = false

    var pinChatSequenceDesc: Bool? = nil
    var allowNewlineSubmit: Bool = false
    var stayAwakeDuringInference: Bool = true
}

struct OverrideCSUISettings {
    var allowContinuation: Bool? = nil
    var showSeparateRetrievalButton: Bool? = nil
    var forceRetrieval: Bool? = nil

    var pinChatSequenceDesc: Bool? = nil
    var allowNewlineSubmit: Bool? = nil
    var stayAwakeDuringInference: Bool? = nil
}

@Observable
class CombinedCSUISettings: ObservableObject {
    var defaults: DefaultCSUISettings
    var override: OverrideCSUISettings

    init(defaults: DefaultCSUISettings, override: OverrideCSUISettings) {
        self.defaults = defaults
        self.override = override
    }

    static func fromNothing() -> CombinedCSUISettings {
        return CombinedCSUISettings(defaults: DefaultCSUISettings(), override: OverrideCSUISettings())
    }

    var allowContinuation: Binding<Bool> {
        return Binding(
            get: { self.override.allowContinuation ?? self.defaults.allowContinuation },
            set: { value in
                self.override.allowContinuation = value
            }
        )
    }

    var stayAwakeDuringInference: Binding<Bool> {
        return Binding(
            get: { self.override.stayAwakeDuringInference ?? self.defaults.stayAwakeDuringInference },
            set: { value in
                self.override.stayAwakeDuringInference = value
            }
        )
    }
}
