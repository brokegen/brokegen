import Foundation
import SwiftyJSON

typealias ProviderType = String
typealias ProviderID = String

/// This is a JSON-decodable string; it's a String in transit because backend treats it as such
typealias ProviderIdentifiers = String

struct ProviderLabel {
    let type: ProviderType
    let id: ProviderID
}

struct ProviderClientModel: Identifiable { //: Equatable, Hashable {
    // TODO: Use the ProviderLabel as the ObjectIdentifier
    let id: UUID = UUID()
    let label: ProviderLabel

    let identifiers: ProviderIdentifiers?
    let createdAt: Date?
    let machineInfo: JSON?
    let humanInfo: JSON?
}

extension ProviderClientModel {
    static func fromJson(_ combinedJson: JSON) throws -> ProviderClientModel {
        let labelJson = combinedJson[0]
        guard labelJson["type"].string != nil else {
            throw ProviderServiceError.invalidResponseContentReturned
        }
        guard labelJson["id"].string != nil else {
            throw ProviderServiceError.invalidResponseContentReturned
        }

        let label = ProviderLabel(
            type: labelJson["type"].string!,
            id: labelJson["id"].string!
        )

        print("[TRACE] ProviderClientModel.fromJson() <= \(combinedJson.description)")

        let recordJson = combinedJson[1]
        return ProviderClientModel(
            label: label,
            identifiers: recordJson["identifiers"].string,
            createdAt: recordJson["created_at"].isoDate,
            machineInfo: recordJson["machine_info"],
            humanInfo: recordJson["human_info"]
        )
    }
}

extension DefaultProviderService {
    public func doFetchAllProviders() async throws {
        let providersData: Data? = await getDataBlocking("/providers/any/.discover")
        guard providersData != nil else { throw ProviderServiceError.noResponseContentReturned }

        for (_, combinedJson) in JSON(providersData!) {
            let newProvider = try ProviderClientModel.fromJson(combinedJson)
            allProviders.removeAll {
                $0.label.id == newProvider.label.id
                && $0.label.type == newProvider.label.type
            }
            allProviders.append(newProvider)
            print("[TRACE] newProvider = \(newProvider)")
        }
    }
}
