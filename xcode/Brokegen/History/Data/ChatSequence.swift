import Alamofire
import Combine
import Foundation
import SwiftData

typealias ChatSequenceServerID = Int

class ChatSequence: Identifiable, Codable {
    let id: UUID
    var serverId: ChatSequenceServerID?

    let humanDesc: String?
    let userPinned: Bool

    var messages: [Message] = []
    let inferenceModelId: InferenceModelRecordID?

    convenience init(_ serverId: ChatSequenceServerID? = nil, data: Data) throws {
        try self.init(clientId: UUID(), serverId: serverId, data: data)
    }

    init(clientId: UUID, serverId: ChatSequenceServerID? = nil, data: Data) throws {
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

    init(
        clientId: UUID,
        serverId: ChatSequenceServerID?,
        humanDesc: String?,
        userPinned: Bool,
        messages: [Message],
        inferenceModelId: InferenceModelRecordID?
    ) {
        self.id = clientId
        self.serverId = serverId
        self.humanDesc = humanDesc
        self.userPinned = userPinned
        self.messages = messages
        self.inferenceModelId = inferenceModelId
    }

    func replaceId(_ newClientId: UUID) -> ChatSequence {
        return ChatSequence(
            clientId: newClientId,
            serverId: self.serverId,
            humanDesc: self.humanDesc,
            userPinned: self.userPinned,
            messages: self.messages,
            inferenceModelId: self.inferenceModelId
        )
    }

    var lastMessageDate: Date? {
        guard !messages.isEmpty else { return nil }
        return messages.last!.createdAt
    }
}

extension ChatSequence: Equatable {
    static func == (lhs: ChatSequence, rhs: ChatSequence) -> Bool {
        if lhs.serverId == nil || rhs.serverId == nil {
            return lhs.id == rhs.id
        }

        return lhs.serverId == rhs.serverId
    }
}

extension ChatSequence: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(serverId)
    }
}

extension ChatSyncService {
    public func fetchSequence(_ sequenceId: ChatSequenceServerID) async -> ChatSequence? {
        do {
            if let entireSequence = await getData("/sequences/\(sequenceId)") {
                return try ChatSequence(sequenceId, data: entireSequence)
            }
        }
        catch {
            print("[ERROR] GET /sequences/\(sequenceId) failed decode, probably")
        }

        return nil
    }

    func fetchPinnedSequences(_ limit: Int? = nil) {
        Task.init {
            var limitQuery = ""
            if limit != nil {
                limitQuery = "?limit=\(limit!)"
            }

            let jsonDict = await getDataAsJson("/sequences/pinned\(limitQuery)")
            guard jsonDict != nil else { return }

            let newSequenceIds: [ChatSequenceServerID] = jsonDict!["sequence_ids"] as? [Int] ?? []
            for newSequenceId in newSequenceIds {
                if let entireSequence = await fetchSequence(newSequenceId) {
                    updateSequences(with: entireSequence)
                }
            }
        }
    }

    func updateSequences(with updatedSequence: ChatSequence) {
        // Keep the first ChatSequence's clientId, in case of duplicates
        var originalClientId: UUID? = nil
        if let removalIndex = self.loadedSequences.firstIndex(where: {
            $0.serverId == updatedSequence.serverId
        }) {
            originalClientId = loadedSequences[removalIndex].id
        }

        // Remove all matching ChatSequences
        self.loadedSequences.removeAll(where: {
            $0.serverId == updatedSequence.serverId
        })

        if let clientId = originalClientId {
            self.loadedSequences.insert(updatedSequence.replaceId(clientId), at: 0)
        }
        else {
            self.loadedSequences.insert(updatedSequence, at: 0)
        }
    }

    func replaceSequenceById(_ originalSequenceId: ChatSequenceServerID?, with updatedSequenceId: ChatSequenceServerID) {
        Task.init {
            var priorSequenceClientId: UUID? = nil
            if originalSequenceId != nil {
                if let removalIndex = self.loadedSequences.firstIndex(where: {
                    $0.serverId == originalSequenceId
                }) {
                    priorSequenceClientId = loadedSequences[removalIndex].id
                }

                self.loadedSequences.removeAll(where: {
                    $0.serverId == originalSequenceId
                })
            }

            do {
                if let updatedSequenceData = await getData("/sequences/\(updatedSequenceId)") {
                    let updatedSequence = try ChatSequence(
                        clientId: priorSequenceClientId ?? UUID(),
                        serverId: updatedSequenceId,
                        data: updatedSequenceData)

                    // Insert new ChatSequences in reverse order, newest at the top
                    self.loadedSequences.insert(updatedSequence, at: 0)
                }
            }
            catch {
                print("[ERROR] Failed to replaceSequenceById(\(originalSequenceId), with: \(updatedSequenceId))")
            }
        }
    }
}
