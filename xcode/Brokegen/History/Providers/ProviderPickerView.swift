import Foundation
import SwiftUI
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
    static func fromJson(_ json: JSON) throws -> ProviderClientModel {
        let labelJson = json[0]
        guard labelJson["type"].string != nil else {
            throw ProviderServiceError.invalidResponseContentReturned
        }
        guard labelJson["id"].string != nil else {
            throw ProviderServiceError.invalidResponseContentReturned
        }

        // TODO: Wasn't the whole point of SwiftyJSON that we don't unpack values manually?
        let label = ProviderLabel(
            type: json[0]["type"].string!,
            id: json[0]["id"].string!
        )

        return ProviderClientModel(
            label: label,
            identifiers: labelJson["identifiers"].string,
            createdAt: labelJson["created_at"].isoDate,
            machineInfo: labelJson["machine_info"],
            humanInfo: labelJson["human_info"]
        )
    }
}

enum ProviderServiceError: Error {
    case noResponseContentReturned
    case invalidResponseContentReturned
}

extension ProviderService {
    public func fetchProvider(byLabel label: ProviderLabel) async -> ProviderClientModel? {
        return nil
    }

    public func fetchAllProviders() async throws -> [ProviderClientModel] {
        var allProviders: [ProviderClientModel] = []

        let providersData: Data? = await self.getData("/providers")
        guard providersData != nil else { throw ProviderServiceError.noResponseContentReturned }

        for (_, providerJson) in JSON(providersData!) {
            if let newProvider = try? ProviderClientModel.fromJson(providerJson) {
                allProviders.append(newProvider)
            }
        }

        return allProviders
    }
}

struct ProviderPickerView: View {
    let providerService: ProviderService

    // TODO: data bindings for this are incorrect
    @State var providers: [ProviderClientModel] = []

    init(providerService: ProviderService) {
        self.providerService = providerService
    }

    var body: some View {
        ScrollView {
            if providers.isEmpty {
                Text("[no providers available]")
            }
            else {
                VStack(spacing: 24) {
                    ForEach(providers) { provider in
                        Text("\(provider.label.type) -- \(provider.label.id)")
                    }
                }
            }
        }
        .onAppear {
            Task {
                do {
                    providers.append(contentsOf: try await providerService.fetchAllProviders())
                }
                catch {}
            }
        }
    }
}
