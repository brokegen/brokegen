import Alamofire
import Foundation
import SwiftyJSON

enum ProviderServiceError: Error {
    case noResponseContentReturned
    case invalidResponseContentReturned
}

@Observable
class ProviderService {
    var allModels: [FoundationModel] = []
    var allProviders: [ProviderClientModel] = []

    func fetchAvailableModels(repeatUntilSuccess: Bool) {}

    var stillFetchingModels: Bool {
        get { false }
    }

    var availableModels: [FoundationModel] {
        get {
            return allModels.filter {
                $0.humanId.contains("instruct")
                // This relies on the way our stats field is implemented, but, fine.
                || $0.displayStats?.count ?? 0 > 1
            }
        }
    }

    public func fetchAllProviders(repeatUntilSuccess: Bool) {}

    var availableProviders: [ProviderClientModel] {
        get { allProviders }
    }

    @MainActor
    func replaceModelById(_ originalModelId: FoundationModelRecordID?, with updatedModel: FoundationModel) {
        var priorClientId: UUID? = nil
        var priorRemovalIndex: Int? = nil

        if originalModelId != nil {
            if let removalIndex = allModels.firstIndex(where: {
                $0.serverId == originalModelId
            }) {
                priorClientId = allModels[removalIndex].id
                priorRemovalIndex = removalIndex
            }

            allModels.removeAll(where: {
                $0.serverId == originalModelId
            })
        }

        if let clientId = priorClientId {
            if priorRemovalIndex != nil {
                allModels.insert(
                    updatedModel.replaceId(clientId),
                    at: priorRemovalIndex!)
            }
            else {
                allModels.append(updatedModel.replaceId(clientId))
            }
        }
        else {
            if priorRemovalIndex != nil {
                allModels.insert(updatedModel, at: priorRemovalIndex!)
            }
            else {
                allModels.append(updatedModel)
            }
        }
    }
}

class DefaultProviderService: ProviderService {
    @ObservationIgnored var serverBaseURL: String
    @ObservationIgnored let session: Alamofire.Session

    @ObservationIgnored var modelFetcher: Task<Void, Never>? = nil
    @ObservationIgnored var providerFetcher: Task<Void, Never>? = nil

    private var modelFetcherComplete: Int = 0
    override var stillFetchingModels: Bool {
        modelFetcherComplete < 1
    }

    init(_ serverBaseURL: String, configuration: URLSessionConfiguration) {
        self.serverBaseURL = serverBaseURL
        self.session = Alamofire.Session(configuration: configuration)
    }

    func getDataBlocking(_ endpoint: String) async -> Data? {
        return try? await withCheckedThrowingContinuation { continuation in
            session.request(
                serverBaseURL + endpoint,
                method: .get
            )
            .response { r in
                switch r.result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    print("[ERROR] Failed GET \(endpoint), \"\(error.localizedDescription)\"")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func doFetchAvailableModels() async throws {
        let allModelsData = await self.getDataBlocking("/providers/any/any/models")
        guard allModelsData != nil else { throw ProviderServiceError.noResponseContentReturned }

        let oldCount = self.allModels.count
        for (_, modelData) in JSON(allModelsData!) {
            let model = FoundationModel(modelData.dictionaryValue)
            //print("[TRACE] Adding FoundationModel #\(model.serverId) => \(self.allModels.count) total models")
            await self.replaceModelById(model.serverId, with: model)
        }

        print("[TRACE] Updated data for \(JSON(allModelsData!).arrayValue.count) foundation models (\(oldCount) => \(self.allModels.count))")
    }

    override func fetchAvailableModels(repeatUntilSuccess: Bool) {
        guard modelFetcher == nil else {
            print("[WARNING] DefaultProviderService.fetchAvailableModels() request already pending, ignoring this call")
            return
        }

        if !repeatUntilSuccess {
            modelFetcher = Task {
                print("[TRACE] DefaultProviderService.fetchAvailableModels(repeatUntilSuccess: \(repeatUntilSuccess)) starting")
                do {
                    try await doFetchAvailableModels()
                    DispatchQueue.main.async {
                        self.modelFetcherComplete += 1
                    }
                }
                catch {}

                DispatchQueue.main.async {
                    self.modelFetcher = nil
                }
            }
        }
        else {
            modelFetcher = Task {
                do {
                    try await doFetchAvailableModels()
                    DispatchQueue.main.async {
                        self.modelFetcherComplete += 1
                    }
                    print("[TRACE] DefaultProviderService.fetchAvailableModels() succeeded")

                    DispatchQueue.main.async {
                        self.modelFetcher = nil
                    }
                }
                catch ProviderServiceError.noResponseContentReturned {
                    print("[ERROR] No content from DefaultProviderService.fetchAvailableModels(), will retry")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)

                    DispatchQueue.main.async {
                        self.modelFetcher = nil
                        self.fetchAvailableModels(repeatUntilSuccess: true)
                    }
                }
                catch {
                    print("[ERROR] Failed DefaultProviderService.fetchAvailableModels(), stopping (\(error))")
                }
            }
        }
    }

    override func fetchAllProviders(repeatUntilSuccess: Bool) {
        guard providerFetcher == nil else { return }

        if !repeatUntilSuccess {
            providerFetcher = Task {
                try? await doFetchAllProviders()

                DispatchQueue.main.async {
                    self.providerFetcher = nil
                }
            }
        }
        else {
            providerFetcher = Task {
                do {
                    try await doFetchAllProviders()

                    DispatchQueue.main.async {
                        self.providerFetcher = nil
                    }
                }
                catch ProviderServiceError.noResponseContentReturned {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)

                    DispatchQueue.main.async {
                        self.providerFetcher = nil
                        self.fetchAllProviders(repeatUntilSuccess: true)
                    }
                }
                catch {
                    print("[ERROR] Couldn't fetchAllProviders(): \(error)")
                }
            }
        }
    }
}
