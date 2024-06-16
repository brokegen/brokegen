import Alamofire
import Foundation
import SwiftyJSON

enum ProviderServiceError: Error {
    case noResponseContentReturned
    case invalidResponseContentReturned
}

class ProviderService: Observable, ObservableObject {
    @Published var allModels: [InferenceModel] = []

    func fetchAvailableModels() async throws {}

    public func fetchAllProviders() async throws -> [ProviderClientModel] {
        return []
    }

    var availableModels: [InferenceModel] {
        get {
            do {
                let predicate = #Predicate<InferenceModel> {
                    $0.humanId.contains("instruct")
                    // This relies on the way our stats field is implemented, but, fine.
                    || $0.stats?.count ?? 0 > 1
                }
                return try allModels.filter(predicate)
            }
            catch {
                return allModels
            }
        }
    }

    @MainActor
    func replaceModelById(_ originalModelId: InferenceModelRecordID?, with updatedModel: InferenceModel) {
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
    var serverBaseURL: String
    let session: Alamofire.Session

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
        print("[TRACE] DefaultProviderService.fetchAvailableModels()")

        let allModelsData = await getDataBlocking("/providers/any/any/models")
        guard allModelsData != nil else { throw ProviderServiceError.noResponseContentReturned }

        for (_, modelData) in JSON(allModelsData!) {
            print("[TRACE] Received modelData: \(modelData["human_id"])")
            let inferenceModel = InferenceModel(modelData.dictionaryValue)
            await self.replaceModelById(inferenceModel.serverId, with: inferenceModel)
        }
    }

    override func fetchAllProviders() async throws -> [ProviderClientModel] {
        return try await doFetchAllProviders()
    }
}
