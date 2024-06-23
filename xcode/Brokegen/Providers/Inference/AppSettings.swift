import SwiftUI

/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: FoundationModelRecordID = -3

@Observable
class AppSettings: ObservableObject {
    @AppStorage("defaultInferenceModelId")
    @ObservationIgnored private var defaultInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID
    @AppStorage("fallbackInferenceModelId")
    @ObservationIgnored private var fallbackInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID
    @AppStorage("chatSummaryModelId")
    @ObservationIgnored private var preferredAutonamingModelId: FoundationModelRecordID = INVALID_MODEL_ID
    @AppStorage("preferredEmbeddingModelId")
    @ObservationIgnored private var preferredEmbeddingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    // MARK: - connecting ProviderService
    private var providerService: ProviderService? = nil

    func link(to providerService: ProviderService) {
        self.providerService = providerService
    }

    var stillPopulating: Bool {
        providerService == nil
    }

    // MARK: - retrieving fully populated models
    var defaultInferenceModel: FoundationModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == defaultInferenceModelId
            }
        }
        set {
            defaultInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    var fallbackInferenceModel: FoundationModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == fallbackInferenceModelId
            }
        }
        set {
            fallbackInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    var preferredAutonamingModel: FoundationModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == preferredAutonamingModelId
            }
        }
        set {
            preferredAutonamingModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    var preferredEmbeddingModel: FoundationModel? {
        get {
            return providerService?.allModels.first {
                $0.serverId == preferredEmbeddingModelId
            }
        }
        set {
            preferredEmbeddingModelId = newValue?.serverId ?? INVALID_MODEL_ID
        }
    }

    // MARK: - misc properties
    @AppStorage("startServicesImmediately")
    @ObservationIgnored var _startServicesImmediately: Bool = true

    var startServicesImmediately: Bool {
        get { _startServicesImmediately }
        set { _startServicesImmediately = newValue }
    }

    @AppStorage("allowExternalTraffic")
    @ObservationIgnored var _allowExternalTraffic: Bool = false

    var allowExternalTraffic: Bool {
        get { _allowExternalTraffic }
        set { _allowExternalTraffic = newValue }
    }

    @AppStorage("showDebugSidebarItems")
    @ObservationIgnored var _showDebugSidebarItems: Bool = true

    var showDebugSidebarItems: Bool {
        get { _showDebugSidebarItems }
        set { _showDebugSidebarItems = newValue }
    }
}
