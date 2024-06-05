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

        if let removalIndex = loadedChatSequences.firstIndex(where: {
            $0.serverId == updatedSequence.serverId
        }) {
            originalClientId = loadedChatSequences[removalIndex].id
        }

        // Remove all matching ChatSequences
        loadedChatSequences.removeAll(where: {
            $0.serverId == updatedSequence.serverId
        })

        if let clientId = originalClientId {
            loadedChatSequences.insert(updatedSequence.replaceId(clientId), at: 0)
        }
        else {
            loadedChatSequences.insert(updatedSequence, at: 0)
        }

        let predicate = #Predicate<ChatSequenceClientModel> {
            $0.sequence.serverId == updatedSequence.serverId
        }
        do {
            for clientModel in try chatSequenceClientModels.filter(predicate) {
                clientModel.sequence = updatedSequence
            }
        }
        catch {}
    }

    func replaceSequenceById(_ originalSequenceId: ChatSequenceServerID?, with updatedSequenceId: ChatSequenceServerID) {
        Task {
            var priorSequenceClientId: UUID? = nil
            if originalSequenceId != nil {
                if let removalIndex = self.loadedChatSequences.firstIndex(where: {
                    $0.serverId == originalSequenceId
                }) {
                    priorSequenceClientId = self.loadedChatSequences[removalIndex].id
                }

                self.loadedChatSequences.removeAll(where: {
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
                    self.loadedChatSequences.insert(updatedSequence, at: 0)

                    let predicate = #Predicate<ChatSequenceClientModel> {
                        $0.sequence.serverId == originalSequenceId
                    }
                    do {
                        for clientModel in try chatSequenceClientModels.filter(predicate) {
                            clientModel.sequence = updatedSequence
                        }
                    }
                }
            }
            catch {
                print("[ERROR] Failed to replaceSequenceById(\(String(describing: originalSequenceId)), with: \(updatedSequenceId))")
            }
        }
    }
}
