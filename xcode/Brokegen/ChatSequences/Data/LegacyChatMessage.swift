import Foundation

class Message: Identifiable, Codable {
    let id: UUID = UUID()
    var serverId: Int?

    let role: String
    let content: String
    let createdAt: Date?

    // TODO: See if we need to handle serverId's correctly, this is basically a dirty stopgap/workaround
    private enum CodingKeys: String, CodingKey {
        case role, content, createdAt
    }

    init(_ serverId: Int? = nil, data: Data) throws {
        self.serverId = serverId

        let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as! [String : Any]
        role = jsonDict["role"] as? String ?? "[invalid]"
        content = jsonDict["content"] as? String ?? ""
        createdAt = jsonDict["created_at"] as? Date
    }

    init(role: String, content: String, createdAt: Date?) {
        self.serverId = nil
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    func appendContent(_ fragment: String) -> Message {
        var newMessage = Message(
            role: self.role,
            content: self.content + fragment,
            createdAt: self.createdAt
        )
        newMessage.serverId = self.serverId

        return newMessage
    }
}

extension Message: Equatable {
    static func == (lhs: Message, rhs: Message) -> Bool {
        if lhs.serverId == nil || rhs.serverId == nil {
            return lhs.id == rhs.id
        }

        return lhs.serverId == rhs.serverId
    }
}

extension Message: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(serverId)
    }
}
