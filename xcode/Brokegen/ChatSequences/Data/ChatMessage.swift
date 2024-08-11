import Alamofire
import Combine
import Foundation
import SwiftUI
import SwiftyJSON


struct ChatMessage {
    let serverId: ChatMessageServerID
    let hostSequenceId: ChatSequenceServerID

    let role: String
    let content: String
    let createdAt: Date
}

extension ChatMessage: Identifiable, Equatable, Hashable {
    var id: ChatMessageServerID {
        serverId
    }

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.serverId == rhs.serverId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(serverId)
    }
}

extension ChatMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case serverId = "message_id", hostSequenceId = "sequence_id", role, content, createdAt
    }

    static func fromData(_ data: Data) throws -> ChatMessage {
        return try jsonDecoder.decode(ChatMessage.self, from: data)
    }
}

struct TemporaryChatMessage: Identifiable {
    let id: UUID = UUID()
    public var role: String?
    public var content: String?
    public var createdAt: Date

    init(role: String? = nil, content: String? = nil, createdAt: Date = Date.now) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

extension TemporaryChatMessage: Equatable, Hashable {
    public static func == (lhs: TemporaryChatMessage, rhs: TemporaryChatMessage) -> Bool {
        if lhs.id != rhs.id {
            return false
        }
        if lhs.role != rhs.role {
            return false
        }
        if lhs.content != rhs.content {
            return false
        }

        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension TemporaryChatMessage: Encodable {
    func asJsonData() throws -> Data {
        return try jsonEncoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, createdAt
    }
}


enum ChatMessageType: Equatable, Hashable {
    case system
    case user
    case assistant
    case unknown(String?)
    case serverInfo
    case serverError
    case clientInfo
    case clientError
}

enum MessageLike: Equatable, Hashable {
    case server(ChatMessage)
    case stored(StoredChatMessage)
    case temporary(TemporaryChatMessage, ChatMessageType = .unknown(nil))

    var messageIdString: String {
        get {
            switch(self) {
            case .server(let m):
                "ChatMessage#\(m.serverId)"
            case .stored(let m):
                "ChatMessage#\(m.serverId)"
            case .temporary(_, let messageType):
                "TemporaryChatMessage \(messageType)"
            }
        }
    }

    var sequenceIdString: String? {
        get {
            switch(self) {
            case .server(let m):
                "ChatSequence#\(m.hostSequenceId)"
            case _:
                nil
            }
        }
    }

    var messageType: ChatMessageType {
        get {
            switch(self) {
            case .server(let m):
                switch(m.role) {
                case "system":
                    return .system
                case "user":
                    return .user
                case "assistant":
                    return .assistant
                default:
                    return .unknown(m.role)
                }
            case .stored(let m):
                switch(m.role) {
                case "system":
                    return .system
                case "user":
                    return .user
                case "assistant":
                    return .assistant
                default:
                    return .unknown(m.role)
                }
            case .temporary(_, let messageType):
                return messageType
            }
        }
    }

    var role: String {
        get {
            switch(self) {
            case .server(let m):
                m.role
            case .stored(let m):
                m.role
            case .temporary(let m, _):
                m.role ?? "[unknown]"
            }
        }
    }

    var content: String {
        get {
            switch(self) {
            case .server(let m):
                m.content
            case .stored(let m):
                m.content
            case .temporary(let m, _):
                m.content ?? ""
            }
        }
    }

    var createdAt: Date? {
        get {
            switch(self) {
            case .server(let m):
                m.createdAt
            case .stored(let m):
                m.createdAt
            case .temporary(let m, _):
                m.createdAt
            }
        }
    }

    var createdAtString: String {
        get {
            switch(self) {
            case .server(let m):
                String(describing: m.createdAt)
            case .stored(let m):
                String(describing: m.createdAt)
            case .temporary(let m, _):
                String(describing: m.createdAt)
            }
        }
    }
}

extension MessageLike: Identifiable {
    var id: Self {
        self
    }
}

extension DefaultChatSyncService {
    func doConstructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID {
        let httpBody = try tempMessage.asJsonData()
        let responseData: Data? = try await postDataBlocking(httpBody, endpoint: "/messages")
        guard responseData != nil else { throw ChatSyncServiceError.invalidResponseContentReturned }

        if let messageId: ChatMessageServerID = JSON(responseData!)["message_id"].int {
            return messageId
        }
        else {
            throw ChatSyncServiceError.invalidResponseContentReturned
        }
    }
}
