import Alamofire
import Combine
import Foundation
import SwiftUI
import SwiftyJSON

struct ChatMessage: Equatable, Hashable {
    let serverId: ChatMessageServerID

    let role: String
    let content: String
    let createdAt: Date
}

extension ChatMessage: Identifiable {
    var id: ChatMessageServerID {
        serverId
    }
}

extension ChatMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case serverId = "id", role, content, createdAt
    }

    static func fromData(_ data: Data) throws -> ChatMessage {
        return try jsonDecoder.decode(ChatMessage.self, from: data)
    }
}

struct TemporaryChatMessage {
    public var role: String
    public var content: String?
    public var createdAt: Date

    init(role: String = "user", content: String? = nil, createdAt: Date = Date.now) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

extension TemporaryChatMessage: Encodable {
    func asJsonData() throws -> Data {
        return try jsonEncoder.encode(self)
    }
}

extension DefaultChatSyncService {
    func doConstructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID {
        let httpBody = try tempMessage.asJsonData()
        let responseData: Data? = try await postDataBlocking(httpBody, endpoint: "/messages")
        guard responseData != nil else { throw ChatSyncServiceError.emptyRequestContent }

        if let messageId: ChatMessageServerID = JSON(responseData!)["message_id"].int {
            return messageId
        }
        else {
            throw ChatSyncServiceError.invalidResponseContentReturned
        }
    }
}
