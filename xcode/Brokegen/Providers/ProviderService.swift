import Alamofire
import Foundation

class ProviderService: Observable, ObservableObject {
    var baseURL: String = "http://127.0.0.1:6635"
    let session: Alamofire.Session = {
        // Increase the TCP timeoutIntervalForRequest to 24 hours (configurable),
        // since we expect Ollama models to sometimes take a long time.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 24 * 3600.0
        configuration.timeoutIntervalForResource = 7 * 24 * 3600.0

        return Alamofire.Session(configuration: configuration)
    }()

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

    @Published var allModels: [InferenceModel] = []

    func getData(_ endpoint: String) async -> Data? {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                session.request(
                    baseURL + endpoint,
                    method: .get
                )
                .response { r in
                    switch r.result {
                    case .success(let data):
                        continuation.resume(returning: data)
                    case .failure(let error):
                        print("GET \(endpoint) failed: " + error.localizedDescription)
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        catch {
            print("GET \(endpoint) failed: exception thrown")
            return nil
        }
    }

    private func getDataAsJsonArray(_ endpoint: String) async -> [Any]? {
        let data = await getData(endpoint)
        guard data != nil else {
            print("GET \(endpoint) returned nil data")
            return nil
        }

        do {
            let jsonArray = try JSONSerialization.jsonObject(with: data!, options: []) as! [Any]
            return jsonArray
        }
        catch {
            let dataDesc = String(data: data!, encoding: .utf8) ?? String(describing: data)
            print("GET \(endpoint) decoding as array failed: \(dataDesc)")
            return nil
        }
    }

    private func getDataAsJsonDict(_ endpoint: String) async -> [String : Any]? {
        let data = await getData(endpoint)
        guard data != nil else {
            print("GET \(endpoint) returned nil data")
            return nil
        }

        do {
            let jsonDict = try JSONSerialization.jsonObject(with: data!, options: []) as! [String : Any]
            return jsonDict
        }
        catch {
            let dataDesc = String(data: data!, encoding: .utf8) ?? String(describing: data)
            print("GET \(endpoint) decoding as dict failed: \(dataDesc)")
            return nil
        }
    }

    /// TODO: The sorting order gets all messed up.
    private func replaceModelById(_ originalModelId: InferenceModelRecordID?, with updatedModel: InferenceModel) {
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

    func fetchAvailableModels() async {
        if let data = await getDataAsJsonDict("/providers/any/any/models") {
            let sortedData = data.sorted(by: { Int($0.0) ?? -1 < Int($1.0) ?? -1 })
            for (_, modelInfo) in sortedData {
                if let modelInfo = modelInfo as? [String : Any?] {
                    let model = InferenceModel(modelInfo)
                    DispatchQueue.main.async {
                        self.replaceModelById(model.serverId, with: model)
                    }
                }
            }
        }
    }
}
