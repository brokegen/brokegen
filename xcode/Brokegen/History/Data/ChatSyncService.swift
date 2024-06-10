import Alamofire
import Combine
import Foundation
import SwiftUI

typealias ChatMessageServerID = Int

func packageDateForServer(_ date: Date?) -> String? {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions.insert(.withFractionalSeconds)

    guard date != nil else { return nil }
    return dateFormatter.string(from: date!)
}

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

    func assignId() throws {
        // Grab an ID from the server.
        var parameters = [
            "role": role,
            "content": content,
        ]

        if let createdAt = packageDateForServer(createdAt) {
            parameters["created_at"] = createdAt
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

/// TODO: Limit scope of ObservableObject to the loadedChatSequences, and see if background refresh improves
/// (right now the entire app gets choppy).
class ChatSyncService: Observable, ObservableObject {
    var serverBaseURL: String = "http://127.0.0.1:6635"
    let session: Alamofire.Session
    let dateFormatter: ISO8601DateFormatter

    init() {
        // Increase the TCP timeoutIntervalForRequest to 24 hours (configurable),
        // since we expect Ollama models to sometimes take a long time.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 24 * 3600.0
        configuration.timeoutIntervalForResource = 7 * 24 * 3600.0

        session = Alamofire.Session(configuration: configuration)

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions.insert(.withFractionalSeconds)
    }

    func getData(_ endpoint: String) async -> Data? {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                session.request(
                    serverBaseURL + endpoint,
                    method: .get
                )
                .response { r in
                    switch r.result {
                    case .success(let data):
                        continuation.resume(returning: data)
                    case .failure(let error):
                        print("GET \(endpoint) failed: " + error.localizedDescription)
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        catch {
            print("GET \(endpoint) failed: exception thrown")
            return nil
        }
    }

    func getDataAsJson(_ endpoint: String) async -> [String : Any]? {
        let data = await getData(endpoint)
        do {
            if data != nil {
                let jsonDict = try JSONSerialization.jsonObject(with: data!, options: []) as! [String : Any]
                return jsonDict
            }
            else {
                return nil
            }
        }
        catch {
            print("GET \(endpoint) decoding failed: \(String(describing: data))")
            return nil
        }
    }

    var chatSequenceClientModels: [ChatSequenceClientModel] = []
    @Published var loadedChatSequences: [ChatSequence] = []

    public func clientModel(for sequence: ChatSequence, inferenceModelSettings: InferenceModelSettings) -> ChatSequenceClientModel {
        if let existingSeq = chatSequenceClientModels.first(where: {
            $0.sequence == sequence
        }) {
            return existingSeq
        }
        else {
            let newModel = ChatSequenceClientModel(sequence, chatService: self, inferenceModelSettings: inferenceModelSettings)
            chatSequenceClientModels.append(newModel)
            return newModel
        }
    }

    /// Used to check when the @Environment was injected correctly;
    /// NavigationStack's Views aren't children of each other, so they have to be re-injected.
    public func ping() {
        print("ChatSyncService ping at \(Date.now)")
    }
}

/// These let us add a new Sequence
extension ChatSyncService {
    private func prettyDate(_ date: Date?) -> String? {
        guard date != nil else { return nil }
        return dateFormatter.string(from: date!)
    }

    func postDataAsJson(_ httpBody: Data?, endpoint: String) async throws -> [String : Any]? {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                serverBaseURL + endpoint
            ) { urlRequest in
                urlRequest.method = .post
                urlRequest.headers = [
                    "Content-Type": "application/json"
                ]
                urlRequest.httpBody = httpBody
            }
            .response { r in
                switch r.result {
                case .success(let data):
                    do {
                        let jsonDict = try JSONSerialization.jsonObject(with: data!, options: []) as! [String : Any]
                        print("POST \(endpoint): \(jsonDict)")
                        continuation.resume(returning: jsonDict)
                    }
                    catch {
                        print("POST \(endpoint) decoding failed: \(String(describing: data))")
                        continuation.resume(returning: nil)
                    }
                case .failure(let error):
                    print("POST \(endpoint) failed: " + error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func doConstructUserMessage(_ message: Message) async -> ChatMessageServerID? {
        let parameters: [String : String?] = [
            "role": message.role,
            "content": message.content,
            // TODO: Figure out how to work this into the normal encoding flow
            "created_at": prettyDate(message.createdAt),
        ]

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            let httpBody: Data = try encoder.encode(parameters)

            let jsonDict = try await postDataAsJson(httpBody, endpoint: "/messages")
            guard jsonDict != nil else { return nil }

            let messageID: ChatMessageServerID? = jsonDict!["message_id"] as? Int
            return messageID
        }
        catch {
            return nil
        }
    }

    func constructUserMessage(_ userPrompt: String) async -> ChatMessageServerID? {
        guard !userPrompt.isEmpty else { return nil }

        let userMessage = Message(
            role: "user",
            content: userPrompt,
            createdAt: Date.now
        )

        return await doConstructUserMessage(userMessage)
    }
}
