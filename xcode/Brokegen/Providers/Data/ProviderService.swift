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

    func fetchAvailableModels() async throws {}

    public func fetchAllProviders() async throws -> [ProviderClientModel] {
        return []
    }

    var availableModels: [FoundationModel] {
        get {
            do {
                let predicate = #Predicate<FoundationModel> {
                    $0.humanId.contains("instruct")
                    // This relies on the way our stats field is implemented, but, fine.
                    || $0.displayStats?.count ?? 0 > 1
                }
                return try allModels.filter(predicate)
            }
            catch {
                return allModels
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

    init(_ serverBaseURL: String, configuration: URLSessionConfiguration) {
        self.serverBaseURL = serverBaseURL
        self.session = Alamofire.Session(configuration: configuration)
    }

    func getDataBlocking(_ endpoint: String) async -> Data? {
        do {
            return try await withCheckedThrowingContinuation { continuation in
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
        catch {
            print("[ERROR] GET \(endpoint) failed, exception thrown")
            return nil
        }
    }

    override func fetchAvailableModels() async throws {
        let allModelsData = await getDataBlocking("/providers/any/any/models")
        guard allModelsData != nil else { throw ProviderServiceError.noResponseContentReturned }

        print("[TRACE] Received modelData for \(JSON(allModelsData!).arrayValue.count) models")
        for (_, modelData) in JSON(allModelsData!) {
            let FoundationModel = FoundationModel(modelData.dictionaryValue)
            await self.replaceModelById(FoundationModel.serverId, with: FoundationModel)
        }
        print("[TRACE] Updated modelData for \(JSON(allModelsData!).arrayValue.count) models")
    }

    override func fetchAllProviders() async throws -> [ProviderClientModel] {
        return try await doFetchAllProviders()
    }
}
