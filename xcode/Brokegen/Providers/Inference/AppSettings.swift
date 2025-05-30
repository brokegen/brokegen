import Combine
import SwiftUI


/// These are represented by `nil` everywhere else in the code, but `@AppStorage` is more simpler.
/// Well, these should only ever be positive integers, anyway.
fileprivate let INVALID_MODEL_ID: FoundationModelRecordID = -3

/// See PersistentCSUISettings for detailed comments and reference implementations.
@Observable
class AppSettings {
    // MARK: - implement caching layer for @AppStorage reads
    @ObservationIgnored private var counter = PassthroughSubject<Int, Never>()
    @ObservationIgnored private var subscriber: AnyCancellable?

    private var isAppActive: Bool = true

    func startUpdater() {
        self.counter.send(-1)

        DispatchQueue.global(qos: .background)
            .asyncAfter(
                deadline: .now()
                + (isAppActive ? appStorageUpdateInterval : 60)
            ) {
                self.startUpdater()
            }
    }

    init() {
        NotificationCenter.default
            .addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                self.isAppActive = false
            }
        NotificationCenter.default
            .addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                self.isAppActive = true
            }

        subscriber = counter
            .throttle(
                for: DispatchQueue.SchedulerTimeType.Stride(floatLiteral: appStorageUpdateInterval),
                scheduler: DispatchQueue.global(qos: .background),
                latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                self!.cached_defaultInferenceModel = self!.live_defaultInferenceModel
                self!.cached_fallbackInferenceModel = self!.live_fallbackInferenceModel
                self!.cached_preferredAutonamingModel = self!.live_preferredAutonamingModel
                self!.cached_preferredEmbeddingModel = self!.live_preferredEmbeddingModel

                self!.cached_showDebugSidebarItems = self!.live_showDebugSidebarItems
                self!.cached_startServicesImmediately = self!.live_startServicesImmediately
                self!.cached_allowExternalTraffic = self!.live_allowExternalTraffic
                self!.cached_serverBaseURL = self!.live_serverBaseURL
            }

        startUpdater()
    }

    // MARK: - retrieving fully populated models
    @AppStorage("defaultInferenceModelId")
    @ObservationIgnored private var stored_defaultInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID

    private var cached_defaultInferenceModel: FoundationModel? = nil

    @ObservationIgnored
    var live_defaultInferenceModel: FoundationModel? {
        get {
            access(keyPath: \.live_defaultInferenceModel)
            guard stored_defaultInferenceModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == stored_defaultInferenceModelId
            }
        }
        set {
            withMutation(keyPath: \.live_defaultInferenceModel) {
                stored_defaultInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
                cached_defaultInferenceModel = newValue
            }
        }
    }

    var defaultInferenceModel: FoundationModel? {
        get { cached_defaultInferenceModel }
        set { live_defaultInferenceModel = newValue }
    }


    @AppStorage("fallbackInferenceModelId")
    @ObservationIgnored private var stored_fallbackInferenceModelId: FoundationModelRecordID = INVALID_MODEL_ID

    private var cached_fallbackInferenceModel: FoundationModel? = nil

    @ObservationIgnored
    var live_fallbackInferenceModel: FoundationModel? {
        get {
            access(keyPath: \.live_fallbackInferenceModel)
            guard stored_fallbackInferenceModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == stored_fallbackInferenceModelId
            }
        }
        set {
            withMutation(keyPath: \.live_fallbackInferenceModel) {
                stored_fallbackInferenceModelId = newValue?.serverId ?? INVALID_MODEL_ID
                cached_fallbackInferenceModel = newValue
            }
        }
    }

    var fallbackInferenceModel: FoundationModel? {
        get { cached_fallbackInferenceModel }
        set { live_fallbackInferenceModel = newValue }
    }


    @AppStorage("preferredAutonamingModelId")
    @ObservationIgnored private var stored_preferredAutonamingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    private var cached_preferredAutonamingModel: FoundationModel? = nil

    @ObservationIgnored
    var live_preferredAutonamingModel: FoundationModel? {
        get {
            access(keyPath: \.live_preferredAutonamingModel)
            guard stored_preferredAutonamingModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == stored_preferredAutonamingModelId
            }
        }
        set {
            withMutation(keyPath: \.live_preferredAutonamingModel) {
                stored_preferredAutonamingModelId = newValue?.serverId ?? INVALID_MODEL_ID
                cached_preferredAutonamingModel = newValue
            }
        }
    }

    var preferredAutonamingModel: FoundationModel? {
        get { cached_preferredAutonamingModel }
        set { live_preferredAutonamingModel = newValue }
    }


    @AppStorage("preferredEmbeddingModelId")
    @ObservationIgnored private var stored_preferredEmbeddingModelId: FoundationModelRecordID = INVALID_MODEL_ID

    private var cached_preferredEmbeddingModel: FoundationModel? = nil

    @ObservationIgnored
    var live_preferredEmbeddingModel: FoundationModel? {
        get {
            access(keyPath: \.live_preferredEmbeddingModel)
            guard stored_preferredEmbeddingModelId != INVALID_MODEL_ID else { return nil }

            return providerService?.allModels.first {
                $0.serverId == stored_preferredEmbeddingModelId
            }
        }
        set {
            withMutation(keyPath: \.live_preferredEmbeddingModel) {
                stored_preferredEmbeddingModelId = newValue?.serverId ?? INVALID_MODEL_ID
                cached_preferredEmbeddingModel = newValue
            }
        }
    }

    var preferredEmbeddingModel: FoundationModel? {
        get { cached_preferredEmbeddingModel }
        set { live_preferredEmbeddingModel = newValue }
    }


    // MARK: - connecting ProviderService
    private var providerService: ProviderService? = nil

    func link(to providerService: ProviderService) {
        self.providerService = providerService
    }

    var stillPopulating: Bool {
        providerService == nil || providerService!.stillFetchingModels
    }

    // MARK: - misc properties
    @AppStorage("showDebugSidebarItems")
    @ObservationIgnored var stored_showDebugSidebarItems: Bool = false

    // This must be set to nil at first, so we force a read from stored_showDebugSidebarItems.
    private var cached_showDebugSidebarItems: Bool? = nil

    @ObservationIgnored
    var live_showDebugSidebarItems: Bool {
        get {
            access(keyPath: \.live_showDebugSidebarItems)
            return stored_showDebugSidebarItems
        }
        set {
            withMutation(keyPath: \.live_showDebugSidebarItems) {
                stored_showDebugSidebarItems = newValue
                cached_showDebugSidebarItems = newValue
            }
        }
    }

    var showDebugSidebarItems: Bool {
        get { cached_showDebugSidebarItems ?? stored_showDebugSidebarItems }
        set { live_showDebugSidebarItems = newValue }
    }


    @AppStorage("startServicesImmediately")
    @ObservationIgnored var stored_startServicesImmediately: Bool = true

    private var cached_startServicesImmediately: Bool? = nil

    @ObservationIgnored
    var live_startServicesImmediately: Bool {
        get {
            access(keyPath: \.live_startServicesImmediately)
            return stored_startServicesImmediately
        }
        set {
            withMutation(keyPath: \.live_startServicesImmediately) {
                stored_startServicesImmediately = newValue
                cached_startServicesImmediately = newValue
            }
        }
    }

    var startServicesImmediately: Bool {
        get { cached_startServicesImmediately ?? stored_startServicesImmediately }
        set { live_startServicesImmediately = newValue }
    }


    @AppStorage("allowExternalTraffic")
    @ObservationIgnored var stored_allowExternalTraffic: Bool = false

    private var cached_allowExternalTraffic: Bool? = nil

    @ObservationIgnored
    var live_allowExternalTraffic: Bool {
        get {
            access(keyPath: \.live_allowExternalTraffic)
            return stored_allowExternalTraffic
        }
        set {
            withMutation(keyPath: \.live_allowExternalTraffic) {
                stored_allowExternalTraffic = newValue
                cached_allowExternalTraffic = newValue
            }
        }
    }

    var allowExternalTraffic: Bool {
        get { cached_allowExternalTraffic ?? stored_allowExternalTraffic }
        set { live_allowExternalTraffic = newValue }
    }


    @AppStorage("serverBaseURL")
    @ObservationIgnored var stored_serverBaseURL: String = "http://127.0.0.1:6635"

    private var cached_serverBaseURL: String? = nil

    @ObservationIgnored
    var live_serverBaseURL: String {
        get {
            access(keyPath: \.live_serverBaseURL)
            return stored_serverBaseURL
        }
        set {
            withMutation(keyPath: \.live_serverBaseURL) {
                stored_serverBaseURL = newValue
                cached_serverBaseURL = newValue
            }
        }
    }

    /// Only returns the serverBaseURL that was available to us on launch.
    private var firstRetrieved_serverBaseURL: String? = nil

    var launch_serverBaseURL: String {
        get {
            if firstRetrieved_serverBaseURL != nil {
                return firstRetrieved_serverBaseURL!
            }

            firstRetrieved_serverBaseURL = live_serverBaseURL
            return firstRetrieved_serverBaseURL!
        }
    }
}
