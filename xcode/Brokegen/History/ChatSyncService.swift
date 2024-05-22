import Alamofire
import Foundation
import SwiftData

class Message: Identifiable {
    let id: UUID = UUID()
    var serverId: Int?

    let role: String
    let content: String

    let createdAt: Date?

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

    func assignId() throws {
        // Grab an ID from the server.
        var parameters = [
            "role": role,
            "content": content,
        ]

        if let createdAt = createdAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            parameters["created_at"] = formatter.string(from: createdAt)
        }

        AF.request(
            "http://127.0.0.1:6635/messages",
            method: .post,
            parameters: parameters,
            encoding: JSONEncoding.default
        )
        .response { r in
            switch r.result {
            case .success(let data):
                do {
                    let jsonDict = try JSONSerialization.jsonObject(with: data!, options: []) as! [String : Any]
                    print("POST /messages: \(jsonDict)")
                    self.serverId = jsonDict["message_id"] as? Int ?? -1
                }
                catch {
                    print("POST /messages decoding failed: \(String(describing: data))")
                }
            case .failure(let error):
                print("POST /messages failed: " + error.localizedDescription)
                return
            }
        }
    }
}

/// TODO: None of this handles nils correctly. We shouldn't have nil.
extension Message: Equatable {
    static func == (lhs: Message, rhs: Message) -> Bool {
        return lhs.id == rhs.id
    }
}

extension Message: Hashable {
    func hashValue() -> Int {
        return id.hashValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
class ChatSyncService: Observable, ObservableObject {
    var loadedMessages: [Message] = []

    func fetchMessage(id: Int) {
        AF.request(
            "http://127.0.0.1:6635/messages/\(id)",
            method: .get
        )
        .response { r in
            switch r.result {
            case .success(let data):
                do {
                    if data != nil {
                        let message = try Message(id, data: data!)
                        self.loadedMessages.append(message)
                        print("GET /messages/\(id): \(message)")
                    }
                }
                catch {
                    print("GET /messages/\(id) failed")
                }
            case .failure(let error):
                print("GET /messages/\(id) failed, " + error.localizedDescription)
                return
            }
        }
    }
}
