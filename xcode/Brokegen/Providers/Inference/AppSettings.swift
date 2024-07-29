import SwiftUI

/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: FoundationModelRecordID = -3

@Observable
class AppSettings {
    @AppStorage("defaultInferenceModelId")
    @ObservationIgnored private var _defaultInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID

    @AppStorage("fallbackInferenceModelId")
    @ObservationIgnored private var _fallbackInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID

    @AppStorage("preferredAutonamingModelId")
    @ObservationIgnored private var _preferredAutonamingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    @AppStorage("preferredEmbeddingModelId")
    @ObservationIgnored private var _preferredEmbeddingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    // MARK: - connecting ProviderService
    private var providerService: ProviderService? = nil

    func link(to providerService: ProviderService) {
        self.providerService = providerService
    }

    var stillPopulating: Bool {
        providerService == nil || providerService!.allModels.isEmpty
    }

    // MARK: - retrieving fully populated models
    @ObservationIgnored
    var defaultInferenceModel: FoundationModel? {
        get {
            access(keyPath: \.defaultInferenceModel)
            guard _defaultInferenceModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == _defaultInferenceModelId
            }
        }
        set {
            withMutation(keyPath: \.defaultInferenceModel) {
                _defaultInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
            }
        }
    }

    @ObservationIgnored
    var fallbackInferenceModel: FoundationModel? {
        get {
            access(keyPath: \.fallbackInferenceModel)
            guard _fallbackInferenceModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == _fallbackInferenceModelId
            }
        }
        set {
            withMutation(keyPath: \.fallbackInferenceModel) {
                _fallbackInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
            }
        }
    }

    @ObservationIgnored
    var preferredAutonamingModel: FoundationModel? {
        get {
            access(keyPath: \.preferredAutonamingModel)
            guard _preferredAutonamingModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == _preferredAutonamingModelId
            }
        }
        set {
            withMutation(keyPath: \.preferredAutonamingModel) {
                _preferredAutonamingModelId = newValue?.serverId ?? INVALID_MODEL_ID
            }
        }
    }

    @ObservationIgnored
    var preferredEmbeddingModel: FoundationModel? {
        get {
            access(keyPath: \.preferredEmbeddingModel)
            guard _preferredEmbeddingModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == _preferredEmbeddingModelId
            }
        }
        set {
            withMutation(keyPath: \.preferredEmbeddingModel) {
                _preferredAutonamingModelId = newValue?.serverId ?? INVALID_MODEL_ID
            }
        }
    }

    // MARK: - misc properties
    @AppStorage("showDebugSidebarItems")
    @ObservationIgnored var _showDebugSidebarItems: Bool = true

    @ObservationIgnored
    var showDebugSidebarItems: Bool {
        get {
            access(keyPath: \.showDebugSidebarItems)
            return _showDebugSidebarItems
        }
        set {
            withMutation(keyPath: \.showDebugSidebarItems) {
                _showDebugSidebarItems = newValue
            }
        }
    }

    @AppStorage("startServicesImmediately")
    @ObservationIgnored var _startServicesImmediately: Bool = true

    @ObservationIgnored
    var startServicesImmediately: Bool {
        get {
            access(keyPath: \.startServicesImmediately)
            return _startServicesImmediately
        }
        set {
            withMutation(keyPath: \.startServicesImmediately) {
                _startServicesImmediately = newValue
            }
        }
    }

    @AppStorage("allowExternalTraffic")
    @ObservationIgnored var _allowExternalTraffic: Bool = false

    @ObservationIgnored
    var allowExternalTraffic: Bool {
        get {
            access(keyPath: \.allowExternalTraffic)
            return _allowExternalTraffic
        }
        set {
            withMutation(keyPath: \.allowExternalTraffic) {
                _allowExternalTraffic = newValue
            }
        }
    }
}
