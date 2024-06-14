import Foundation
import SwiftyJSON

public enum JSONObject: Codable {
    case string(String)
    case number(Float)
    case object([String:JSONObject])
    case array([JSONObject])
    case bool(Bool)
    case null
}

/// TODO: Replace use of Codable with SwiftyJSON
/// This makes more sense for very-variable JSON blobs, particularly those that don't have explicit typing
/// (i.e. those not under our control, like whatever fields come down for provider/modelIdentifiers).
extension JSON {
    private static let isoDateFormatter: ISO8601DateFormatter = {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return dateFormatter
    }()

    public var isoDate: Date? {
        get {
            if let objectString = self.string {
                return JSON.isoDateFormatter.date(from: objectString + "Z")
            }
            else {
                return nil
            }
        }
    }

    public var isoDateValue: Date {
        get {
            return self.isoDate ?? Date.init(timeIntervalSinceReferenceDate: 0)
        }
        set {
            self.stringValue = JSON.isoDateFormatter.string(from: newValue)
        }
    }
}

typealias InferenceModelRecordID = Int
typealias InferenceEventID = Int

public struct InferenceModel: Identifiable {
    public let id: UUID
    public let serverId: Int

    public let humanId: String
    public let firstSeenAt: Date?
    public let lastSeen: Date?

    public let providerIdentifiers: String
    public let modelIdentifiers: [String : Any]?

    public let combinedInferenceParameters: JSONObject?

    /// Additional inference stats, added if available.
    /// Surfaced to client for the sake of sorting models + choosing ones they'd probably want.
    public let stats: [String : Any]?
    /// Redundant with the providerIdentifiers; this should be source of truth.
    public let label: [String : String]?
}

extension InferenceModel {
    init(_ jsonDict: [String: Any?]) {
        self.init(clientId: UUID(), jsonDict: jsonDict)
    }

    init(clientId: UUID, jsonDict: [String: Any?]) {
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
            id: clientId,
            serverId: jsonDict["id"] as! Int,
            humanId: jsonDict["human_id"] as! String,
            firstSeenAt: firstSeenAt0,
            lastSeen: lastSeen0,
            providerIdentifiers: jsonDict["provider_identifiers"] as! String,
            modelIdentifiers: (jsonDict["model_identifiers"] as! [String : Any]),
            combinedInferenceParameters: jsonDict["combined_inference_parameters"] as? JSONObject,
            stats: (jsonDict["stats"] as? [String : Any]),
            label: (jsonDict["label"] as? [String : String])
        )
    }

    func replaceId(_ newClientId: UUID) -> InferenceModel {
        return InferenceModel(
            id: newClientId,
            serverId: self.serverId,
            humanId: self.humanId,
            firstSeenAt: self.firstSeenAt,
            lastSeen: self.lastSeen,
            providerIdentifiers: self.providerIdentifiers,
            modelIdentifiers: self.modelIdentifiers,
            combinedInferenceParameters: self.combinedInferenceParameters,
            stats: self.stats,
            label: self.label
        )
    }
}

extension InferenceModel: Equatable {
    public static func == (lhs: InferenceModel, rhs: InferenceModel) -> Bool {
        if lhs.serverId != rhs.serverId {
            return false
        }

        if lhs.id != rhs.id {
            return false
        }

        return true
    }
}

extension InferenceModel: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(serverId)
    }
}
