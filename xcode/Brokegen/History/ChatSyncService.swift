import Alamofire
import Combine
import Foundation
import SwiftData

class Message: Identifiable, Codable {
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

class ChatSequence: Identifiable, Codable {
    let id: UUID = UUID()
    var serverId: Int?

    let humanDesc: String?
    let userPinned: Bool

    var messages: [Message] = []

    init(_ serverId: Int? = nil, data: Data) throws {
        self.serverId = serverId

        let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as! [String : Any]
        humanDesc = jsonDict["human_desc"] as? String
        userPinned = jsonDict["user_pinned"] != nil

        let messagesJsonList = jsonDict["messages"] as? [[String : Any]]
        for messageJson in messagesJsonList! {
            let newMessage = Message(
                role: messageJson["role"] as? String ?? "[invalid]",
                content: messageJson["content"] as? String ?? "",
                createdAt: messageJson["created_at"] as? Date
            )
            newMessage.serverId = messageJson["id"] as? Int

            print("[DEBUG] Added message \(newMessage.serverId ?? -1) to Sequence#\(self.serverId!)")
            messages.append(newMessage)
        }
    }
}

@Observable
class ChatSyncService: Observable, ObservableObject {
    var serverBaseURL: String = "http://127.0.0.1:6635"
    let session: Alamofire.Session = {
        // Increase the TCP timeoutIntervalForRequest to 24 hours (configurable),
        // since we expect Ollama models to sometimes take a long time.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 24 * 3600.0
        configuration.timeoutIntervalForResource = 7 * 24 * 3600.0

        return Alamofire.Session(configuration: configuration)
    }()

    private func getData(_ endpoint: String) async -> Data? {
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

    private func getDataAsJson(_ endpoint: String) async -> [String : Any]? {
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

    var loadedMessages: [Message] = []

    func fetchMessage(id: Int) {
        Task.init {
            if let data = await getData("/messages/\(id)") {
                let message = try Message(id, data: data)
                self.loadedMessages.append(message)
            }
        }
    }

    var loadedSequences: [ChatSequence] = []

    func fetchPinnedSequences() {
        Task.init {
            let jsonDict = await getDataAsJson("/sequences/pinned")
            guard jsonDict != nil else { return }

            let sequenceIds: [Int] = jsonDict!["sequence_ids"] as? [Int] ?? []
            for seqId in sequenceIds {
                do {
                    if let entireSequence = await getData("/sequences/\(seqId)") {
                        let newSeq = try ChatSequence(seqId, data: entireSequence)
                        self.loadedSequences.append(newSeq)
                    }
                }
                catch {
                    print("[ERROR] Failed to get sequence data for \(seqId)")
                }
            }
        }
    }
}

/// Finally, something to submit new chat requests
extension ChatSyncService {
    public func streamGenerate(
        _ userPrompt: String,
        id sequenceId: Int
    ) async -> AnyPublisher<Data, AFError> {
        let subject = PassthroughSubject<Data, AFError>()

        struct Parameters: Codable {
            var userPrompt: String
            var sequenceId: Int
        }

        let parameters = Parameters(userPrompt: userPrompt, sequenceId: sequenceId)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        _ = session.streamRequest(
            serverBaseURL + "/generate"
        ) { urlRequest in
            urlRequest.method = .post
            urlRequest.headers = [
                "Content-Type": "application/json"
            ]
            urlRequest.httpBody = try encoder.encode(parameters)
        }
        .responseStream { stream in
            switch stream.event {
            case let .stream(result):
                switch result {
                case let .success(data):
                    subject.send(data)
                }
            case let .complete(completion):
                if completion.error == nil {
                    subject.send(completion: .finished)
                }
                else {
                    subject.send(completion: .failure(completion.error!))
                }
            }
        }

        return subject.eraseToAnyPublisher()
    }
}
