import Foundation
import SwiftData


@Model
class StoredChatMessage {
    let serverId: ChatMessageServerID
    let role: String
    let content: String
    let createdAt: Date

    init(
        serverId: ChatMessageServerID,
        role: String,
        content: String,
        createdAt: Date
    ) {
        self.serverId = serverId
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

extension StoredChatMessage: Identifiable, Equatable, Hashable {
    var id: ChatMessageServerID {
        serverId
    }

    public static func == (lhs: StoredChatMessage, rhs: StoredChatMessage) -> Bool {
        return lhs.serverId == rhs.serverId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(serverId)
    }
}
