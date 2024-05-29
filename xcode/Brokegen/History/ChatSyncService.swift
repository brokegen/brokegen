import Alamofire
import Combine
import Foundation
import SwiftData

typealias ChatMessageServerID = Int
typealias ChatSequenceServerID = Int

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
    let id: UUID
    var serverId: Int?

    let humanDesc: String?
    let userPinned: Bool

    var messages: [Message] = []
    let inferenceModelId: Int?

    convenience init(_ serverId: Int? = nil, data: Data) throws {
        try self.init(clientId: UUID(), serverId: serverId, data: data)
    }

    init(clientId: UUID, serverId: Int? = nil, data: Data) throws {
        self.id = clientId
        self.serverId = serverId

        let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as! [String : Any]
        humanDesc = jsonDict["human_desc"] as? String
        userPinned = jsonDict["user_pinned"] != nil

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let messagesJsonList = jsonDict["messages"] as? [[String : Any]]
        for messageJson in messagesJsonList! {
            var createdAt0: Date? = nil
            if let createdAt1 = messageJson["created_at"] as? String {
                if let createdAt2 = dateFormatter.date(from: createdAt1 + "Z") {
                    createdAt0 = createdAt2
                }
            }

            let newMessage = Message(
                role: messageJson["role"] as? String ?? "[invalid]",
                content: messageJson["content"] as? String ?? "",
                createdAt: createdAt0
            )
            newMessage.serverId = messageJson["id"] as? Int

            //print("[DEBUG] Added message \(newMessage.serverId ?? -1) to Sequence#\(self.serverId!)")
            messages.append(newMessage)
        }

        inferenceModelId = jsonDict["inference_model_id"] as? Int
    }

    var lastMessageDate: Date? {
        guard !messages.isEmpty else { return nil }
        return messages.last!.createdAt
    }
}

actor CachedChatMessages {
    var cachedChatMessages: [Message] = []

    func append(_ message: Message) {
        cachedChatMessages.append(message)
    }
}

@Observable
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

    var loadedMessages: CachedChatMessages = CachedChatMessages()

    func fetchMessage(id: Int) {
        Task.init {
            if let data = await getData("/messages/\(id)") {
                let message = try Message(id, data: data)
                await self.loadedMessages.append(message)
            }
        }
    }

    var loadedSequences: [ChatSequence] = []

    func fetchPinnedSequences(_ limit: Int? = nil) {
        Task.init {
            var limitQuery = ""
            if limit != nil {
                limitQuery = "?limit=\(limit!)"
            }

            let jsonDict = await getDataAsJson("/sequences/pinned\(limitQuery)")
            guard jsonDict != nil else { return }

            // Clear out the entire set of existing sequences
            self.loadedSequences = []

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

    func replaceSequence(_ originalSequenceId: ChatSequenceServerID?, with updatedSequenceId: ChatSequenceServerID) {
        Task.init {
            var priorSequenceClientId: UUID? = nil
            if originalSequenceId != nil {
                if let removalIndex = self.loadedSequences.firstIndex(where: { $0.serverId == originalSequenceId }) {
                    let oldSequence = loadedSequences[removalIndex]
                    priorSequenceClientId = oldSequence.id
                    loadedSequences.remove(at: removalIndex)
                }
            }

            do {
                if let entireSequence = await getData("/sequences/\(updatedSequenceId)") {
                    let newSeq = try ChatSequence(clientId: priorSequenceClientId ?? UUID(), serverId: updatedSequenceId, data: entireSequence)
                    self.loadedSequences.insert(newSeq, at: 0)
                }
            }
            catch {
                print("[ERROR] Failed to add updated sequence \(originalSequenceId) => \(updatedSequenceId)")
            }
        }
    }
}

/// These let us add a new Sequence
extension ChatSyncService {
    private func prettyDate(_ date: Date?) -> String? {
        guard date != nil else { return nil }
        return dateFormatter.string(from: date!)
    }

    func postData(_ httpBody: Data?, endpoint: String) async throws -> [String : Any]? {
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

    private func constructMessage(_ message: Message) async -> ChatMessageServerID? {
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

            let jsonDict = try await postData(httpBody, endpoint: "/messages")
            guard jsonDict != nil else { return nil }

            let messageID: ChatMessageServerID? = jsonDict!["message_id"] as? Int
            return messageID
        }
        catch {
            return nil
        }
    }

    func constructUserMessage(_ userPrompt: String) async -> ChatMessageServerID? {
        let userMessage = Message(
            role: "user",
            content: userPrompt,
            createdAt: Date.now
        )

        return await constructMessage(userMessage)
    }
}

/// Finally, something to submit new chat requests
extension ChatSyncService {
    public func sequenceContinue(
        _ sequenceId: ChatSequenceServerID,
        model continuationModelId: InferenceModelRecordID? = nil
    ) async -> AnyPublisher<Data, AFError> {
        let subject = PassthroughSubject<Data, AFError>()

        struct Parameters: Codable {
            let continuationModelId: InferenceModelRecordID?
        }
        let parameters = Parameters(continuationModelId: continuationModelId)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            print("[DEBUG] POST /sequences/\(sequenceId)/continue <= \(String(data: try encoder.encode(parameters), encoding: .utf8)!)")

            _ = session.streamRequest(
                serverBaseURL + "/sequences/\(sequenceId)/continue"
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
        }
        catch {
            print("[ERROR] /sequences/\(sequenceId)/continue failed, probably encoding error: \(String(describing: parameters))")
        }

        return subject.eraseToAnyPublisher()
    }

    public func sequenceExtend(
        _ nextMessage: Message,
        id sequenceId: ChatSequenceServerID,
        model continuationModelId: InferenceModelRecordID? = nil
    ) async -> AnyPublisher<Data, AFError> {
        let subject = PassthroughSubject<Data, AFError>()

        struct Parameters: Codable {
            let nextMessage: Message
            let continuationModelId: InferenceModelRecordID?
        }
        let parameters = Parameters(nextMessage: nextMessage, continuationModelId: continuationModelId)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        do {
            print("[DEBUG] POST /sequences/\(sequenceId)/extend <= \(String(data: try encoder.encode(parameters), encoding: .utf8)!)")

            _ = session.streamRequest(
                serverBaseURL + "/sequences/\(sequenceId)/extend"
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
        }
        catch {
            print("[ERROR] /sequences/\(sequenceId)/extend failed, probably encoding error: \(String(describing: parameters))")
        }

        return subject.eraseToAnyPublisher()
    }
}
