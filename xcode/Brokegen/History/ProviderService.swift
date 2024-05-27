import Alamofire
import Combine
import Foundation
import SwiftData

public enum JSONObject: Codable {
    case string(String)
    case number(Float)
    case object([String:JSONObject])
    case array([JSONObject])
    case bool(Bool)
    case null
}

public struct InferenceModel: Identifiable {
    public let id: UUID = UUID()
    public let serverId: Int

    public let humanId: String
    public let firstSeenAt: Date?
    public let lastSeen: Date?

    public let providerIdentifiers: String
    public let modelIdentifiers: [String : Any]?

    public let combinedInferenceParameters: JSONObject?

    /// Additional inference stats, added if available.
    /// Surfaced to client for the sake of sorting models + choosing ones they'd probably want.
    public let stats: JSONObject?
}

extension InferenceModel {
    init(_ jsonDict: [String: Any?]) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var firstSeenAt0: Date? = nil
        if let firstSeenAt1 = jsonDict["first_seen_at"] as? String {
            if let firstSeenAt2 = dateFormatter.date(from: firstSeenAt1 + "Z") {
                firstSeenAt0 = firstSeenAt2
            }
        }

        var lastSeen0: Date? = nil
        if let lastSeen1 = jsonDict["last_seen"] as? String {
            if let lastSeen2 = dateFormatter.date(from: lastSeen1 + "Z") {
                lastSeen0 = lastSeen2
            }
        }

        self.init(
            serverId: jsonDict["id"] as! Int,
            humanId: jsonDict["human_id"] as! String,
            firstSeenAt: firstSeenAt0,
            lastSeen: lastSeen0,
            providerIdentifiers: jsonDict["provider_identifiers"] as! String,
            modelIdentifiers: (jsonDict["model_identifiers"] as! [String : Any]),
            combinedInferenceParameters: jsonDict["combined_inference_parameters"] as? JSONObject,
            stats: jsonDict["stats"] as? JSONObject
        )
    }
}

@Observable
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

    var availableModels: [InferenceModel] = []

    private func getData(_ endpoint: String) async -> Data? {
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

    func fetchAvailableModels() {
        Task.init {
            if let data = await getDataAsJsonDict("/models/available") {
                for (_, modelInfo) in data {
                    let model = InferenceModel(modelInfo as! [String : Any?])
                    availableModels.append(model)
                }
            }
        }
    }
}
