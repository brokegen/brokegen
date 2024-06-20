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
            return self.isoDate ?? Date.distantPast
        }
        set {
            self.stringValue = JSON.isoDateFormatter.string(from: newValue)
        }
    }
}

typealias FoundationModelRecordID = Int
typealias InferenceEventID = Int

public struct FoundationModel: Identifiable {
    public let id: UUID
    public let serverId: Int

    public let humanId: String
    public let firstSeenAt: Date?
    public let lastSeen: Date?

    public let providerIdentifiers: String
    public let modelIdentifiers: [String : Any]?

    public let combinedInferenceParameters: JSON

    /// Additional inference stats, added if available.
    /// Surfaced to client for the sake of sorting models + choosing ones they'd probably want.
    public let stats: [String : Any]?
    /// Redundant with the providerIdentifiers; this should be source of truth.
    public let label: [String : JSON]?
}

extension FoundationModel {
    static func fromData(_ data: Data) -> FoundationModel {
        let jsonModel = JSON(data)
        return FoundationModel(jsonModel)
    }

    init(_ jsonModel: [String: Any?]) {
        self.init(JSON(jsonModel))
    }

    init(_ jsonModel: JSON) {
        self.init(
            id: UUID(),
            serverId: jsonModel["id"].int!,
            humanId: jsonModel["human_id"].stringValue,
            firstSeenAt: jsonModel["first_seen_at"].isoDate,
            lastSeen: jsonModel["last_seen"].isoDate,
            providerIdentifiers: jsonModel["provider_identifiers"].string!,
            modelIdentifiers: jsonModel["model_identifiers"].dictionary,
            combinedInferenceParameters: jsonModel["combined_inference_parameters"],
            stats: jsonModel["stats"].dictionary,
            label: jsonModel["label"].dictionary)
    }

    func replaceId(_ newClientId: UUID) -> FoundationModel {
        return FoundationModel(
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

extension FoundationModel: Equatable {
    public static func == (lhs: FoundationModel, rhs: FoundationModel) -> Bool {
        if lhs.serverId != rhs.serverId {
            return false
        }

        if lhs.id != rhs.id {
            return false
        }

        return true
    }
}

extension FoundationModel: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(serverId)
    }
}
