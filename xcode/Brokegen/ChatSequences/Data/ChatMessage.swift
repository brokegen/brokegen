import Alamofire
import Combine
import Foundation
import SwiftUI
import SwiftyJSON

struct ChatMessage: Equatable {
    let serverId: ChatMessageServerID
    let hostSequenceId: ChatSequenceServerID?

    let role: String
    let content: String
    let createdAt: Date
}

extension ChatMessage: Hashable, Identifiable {
    var id: Self {
        self
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

struct TemporaryChatMessage: Equatable, Hashable {
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

enum MessageLike: Equatable, Hashable {
    case legacy(Message)
    case stored(ChatMessage)
    case temporary(TemporaryChatMessage)

    var serverIdStr: String {
        get {
            switch(self) {
            case .legacy(let m):
                m.serverId == nil ? "[unknown ChatMessage]" : "ChatMessage#\(m.serverId!)"
            case .stored(let m):
                "ChatMessage#\(m.serverId)"
            case .temporary(_):
                "TemporaryChatMessage"
            }
        }
    }

    var role: String {
        get {
            switch(self) {
            case .legacy(let m):
                m.role
            case .stored(let m):
                m.role
            case .temporary(let m):
                m.role
            }
        }
    }

    var content: String {
        get {
            switch(self) {
            case .legacy(let m):
                m.content
            case .stored(let m):
                m.content
            case .temporary(let m):
                m.content ?? ""
            }
        }
    }

    var createdAt: Date? {
        get {
            switch(self) {
            case .legacy(let m):
                m.createdAt

            case .stored(let m):
                m.createdAt

            case .temporary(let m):
                m.createdAt
            }
        }
    }

    var createdAtString: String {
        get {
            switch(self) {
            case .legacy(let m):
                if m.createdAt != nil {
                    String(describing: m.createdAt!)
                }
                else {
                    "[unknown date]"
                }
            case .stored(let m):
                String(describing: m.createdAt)
            case .temporary(let m):
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
