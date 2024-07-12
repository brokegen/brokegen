import Alamofire
import Foundation
import SwiftyJSON

enum ProviderServiceError: Error {
    case noResponseContentReturned
    case invalidResponseContentReturned
}

@Observable
class ProviderService: ObservableObject {
    var allModels: [FoundationModel] = []

    func fetchAvailableModels(repeatUntilSuccess: Bool) {}

    public func fetchAllProviders(repeatUntilSuccess: Bool) async throws -> [ProviderClientModel] {
        return []
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
                    print("[ERROR] GET \(endpoint) failed, " + error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func doFetchAvailableModels() async throws {
        let allModelsData = await self.getDataBlocking("/providers/any/any/models")
        guard allModelsData != nil else { throw ProviderServiceError.invalidResponseContentReturned }

        let oldCount = self.allModels.count
        for (_, modelData) in JSON(allModelsData!) {
            let FoundationModel = FoundationModel(modelData.dictionaryValue)
            await self.replaceModelById(FoundationModel.serverId, with: FoundationModel)
        }
        print("[TRACE] Updated data for \(JSON(allModelsData!).arrayValue.count) foundation models (\(oldCount) => \(self.allModels.count))")
    }

    override func fetchAvailableModels(repeatUntilSuccess: Bool) {
        print("[TRACE] DefaultProviderService.fetchAvailableModels() starting")
        guard modelFetcher == nil else { return }

        if !repeatUntilSuccess {
            modelFetcher = Task {
                try? await doFetchAvailableModels()

                DispatchQueue.main.async {
                    self.modelFetcher = nil
                }
            }
        }
        else {
            modelFetcher = Task {
                do {
                    try await doFetchAvailableModels()
                }
                catch {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)

                    DispatchQueue.main.async {
                        self.modelFetcher = nil
                        self.fetchAvailableModels(repeatUntilSuccess: true)
                    }
                }
            }
        }
    }

    override func fetchAllProviders(repeatUntilSuccess: Bool) async throws -> [ProviderClientModel] {
        return try await doFetchAllProviders(repeatUntilSuccess: repeatUntilSuccess)
    }
}
