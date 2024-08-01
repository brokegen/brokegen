import Combine
import SwiftUI

/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: FoundationModelRecordID = -3

@Observable
class AppSettings {
    public var cached_preferredAutonamingModel: FoundationModel? = nil
    public var cached_preferredEmbeddingModel: FoundationModel? = nil

    // MARK: - implement caching layer for @AppStorage reads
    @ObservationIgnored private var counter = PassthroughSubject<Int, Never>()
    @ObservationIgnored private var subscriber: AnyCancellable?

    func startUpdater() {
        self.counter.send(-1)

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.3) {
            self.startUpdater()
        }
    }

    init() {
        // https://stackoverflow.com/questions/63678438/swiftui-updating-ui-with-high-frequency-data
        //
        // NB We're implementing a (not-optimal) multi-step approach, where
        // the extra variables are a read-only cache that reads from system preferences once every second or so.
        //
        subscriber = counter
            // Drop updates in the background
            .throttle(for: 1.1, scheduler: DispatchQueue.global(qos: .background), latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                self!.cached_preferredAutonamingModel = self!.preferredAutonamingModel
            }

        startUpdater()
    }

    // MARK: - retrieving fully populated models
    @AppStorage("defaultInferenceModelId")
    @ObservationIgnored private var _defaultInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID

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

    @AppStorage("fallbackInferenceModelId")
    @ObservationIgnored private var _fallbackInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID

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

    @AppStorage("preferredAutonamingModelId")
    @ObservationIgnored private var stored_preferredAutonamingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    @ObservationIgnored
    var preferredAutonamingModel: FoundationModel? {
        get {
            access(keyPath: \.preferredAutonamingModel)
            guard stored_preferredAutonamingModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == stored_preferredAutonamingModelId
            }
        }
        set {
            withMutation(keyPath: \.preferredAutonamingModel) {
                stored_preferredAutonamingModelId = newValue?.serverId ?? INVALID_MODEL_ID
                cached_preferredAutonamingModel = newValue
            }
        }
    }

    @AppStorage("preferredEmbeddingModelId")
    @ObservationIgnored private var stored_preferredEmbeddingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    @ObservationIgnored
    var preferredEmbeddingModel: FoundationModel? {
        get {
            access(keyPath: \.preferredEmbeddingModel)
            guard stored_preferredEmbeddingModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == stored_preferredEmbeddingModelId
            }
        }
        set {
            withMutation(keyPath: \.preferredEmbeddingModel) {
                stored_preferredEmbeddingModelId = newValue?.serverId ?? INVALID_MODEL_ID
                cached_preferredEmbeddingModel = newValue
            }
        }
    }

    // MARK: - connecting ProviderService
    private var providerService: ProviderService? = nil

    func link(to providerService: ProviderService) {
        self.providerService = providerService
    }

    var stillPopulating: Bool {
        providerService == nil || providerService!.allModels.isEmpty
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
