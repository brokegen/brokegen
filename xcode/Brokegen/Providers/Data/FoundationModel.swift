import Foundation
import SwiftyJSON

typealias FoundationModelRecordID = Int
typealias InferenceEventID = Int

public struct FoundationModel: Identifiable {
    public let id: UUID
    public let serverId: Int

    public let humanId: String
    public let firstSeenAt: Date?
    public let lastSeen: Date?

    public let providerIdentifiers: String
    public let modelIdentifiers: JSON?

    public let combinedInferenceParameters: JSON

    /// Additional inference stats, added if available.
    /// Surfaced to client for the sake of sorting models + choosing ones they'd probably want.
    public let displayStats: JSON?
    public let allStats: JSON?

    /// Redundant with the providerIdentifiers; this should be source of truth.
    public let label: [String : JSON]?
    public let available: Bool

    public let latestInferenceEvent: Date?
    public let recentInferenceEvents: Int
    public let recentTokensPerSecond: Float
}

extension FoundationModel: CustomStringConvertible {
    public var description: String {
        let maybeLabel = label?["type"]?.string != nil
        ? "[\(label!["type"]!.string!)] "
        : ""

        return "\(maybeLabel)FoundationModel#\(serverId): \(humanId)"
    }
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
            modelIdentifiers: jsonModel["model_identifiers"],
            combinedInferenceParameters: jsonModel["combined_inference_parameters"],
            displayStats: jsonModel["display_stats"],
            allStats: jsonModel["all_stats"],
            label: jsonModel["label"].dictionary,
            available: jsonModel["available"].boolValue,
            latestInferenceEvent: jsonModel["latest_inference_event"].isoDate,
            recentInferenceEvents: jsonModel["recent_inference_events"].intValue,
            recentTokensPerSecond: jsonModel["recent_tokens_per_second"].floatValue
        )
    }
}

extension FoundationModel: Equatable {
    public static func == (lhs: FoundationModel, rhs: FoundationModel) -> Bool {
        return lhs.id == rhs.id && lhs.serverId == rhs.serverId
    }
}

extension FoundationModel: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(serverId)
    }
}
