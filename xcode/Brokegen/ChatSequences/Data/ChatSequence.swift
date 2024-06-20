import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

typealias ChatSequenceServerID = Int

class ChatSequence: Identifiable, Codable {
    let id: UUID
    var serverId: ChatSequenceServerID?

    let humanDesc: String?
    let userPinned: Bool

    /// This list is not synced with anything on the server; this is intentional.
    /// Only messages that are first uploaded to the server, and recorded with ChatSequence nodes, will get processed.
    ///
    /// Put a different way, this list is entirely a client-side construction/interpretation of messages returned to us.
    ///
    var messages: [Message] = []
    let inferenceModelId: FoundationModelRecordID?

    static func createBlank() -> ChatSequence {
        return ChatSequence(
            clientId: UUID(),
            serverId: nil,
            humanDesc: nil,
            userPinned: false,
            messages: [
                Message(role: "placeholder", content: "", createdAt: nil),
            ],
            inferenceModelId: nil)
    }

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
        inferenceModelId: FoundationModelRecordID?
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

extension DefaultChatSyncService {
    func doConstructNewChatSequence(messageId: ChatMessageServerID, humanDesc: String = "") async throws -> ChatSequenceServerID? {
        struct Parameters: Codable {
            var humanDesc: String? = nil
            var userPinned: Bool
            let currentMessage: ChatMessageServerID
            var parentSequence: ChatSequenceServerID? = nil
            var generatedAt: Date?
            var generationComplete: Bool
            var inferenceJobId: InferenceEventID? = nil
            var inferenceError: String? = nil
        }
        let params = Parameters(
            humanDesc: humanDesc.isEmpty ? nil : humanDesc,
            userPinned: true,
            currentMessage: messageId,
            generatedAt: Date.now,
            generationComplete: true
        )

        do {
            let encodedParams = try jsonEncoder.encode(params)

            let jsonDict = try await self.postDataAsJson(
                encodedParams,
                endpoint: "/sequences")
            guard jsonDict != nil else { return nil }

            let sequenceID: ChatMessageServerID? = jsonDict!["sequence_id"] as? Int
            return sequenceID
        }
        catch {
            return nil
        }
    }

    func doRefreshPinnedChatSequences(lookback: TimeInterval?, limit: Int?) async throws {
        var endpointMaker = "/sequences/pinned?"
        if lookback != nil {
            endpointMaker += "&lookback=\(lookback!)"
        }
        if limit != nil {
            endpointMaker += "&limit=\(limit!)"
        }

        let sequenceIds = try await getDataBlocking(endpointMaker)
        guard sequenceIds != nil else { throw ChatSyncServiceError.noResponseContentReturned }

        for (_, newSequenceId) in JSON(sequenceIds!)["sequence_ids"] {
            if newSequenceId.int == nil {
                print("[ERROR] Got nil sequenceId from \(endpointMaker)")
                continue
            }

            if let entireSequence = try await doFetchChatSequenceDetails(newSequenceId.int!) {
                DispatchQueue.main.async {
                    self.updateSequence(withSameId: entireSequence)
                }
            }
        }
    }

    public func doFetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        if let entireSequence = try await getDataBlocking("/sequences/\(sequenceId)") {
            return try ChatSequence(sequenceId, data: entireSequence)
        }
        else {
            throw ChatSyncServiceError.noResponseContentReturned
        }
    }

    func doUpdateSequence(originalSequenceId: ChatSequenceServerID?, updatedSequenceId: ChatSequenceServerID) async -> ChatSequence? {
        var priorSequenceClientId: UUID? = nil
        if originalSequenceId != nil {
            if let removalIndex = self.loadedChatSequences.firstIndex(where: {
                $0.serverId == originalSequenceId
            }) {
                priorSequenceClientId = self.loadedChatSequences[removalIndex].id
            }

            DispatchQueue.main.async {
                self.loadedChatSequences.removeAll(where: {
                    $0.serverId == originalSequenceId
                })
            }
        }

        if let updatedSequenceData = try? await getDataBlocking("/sequences/\(updatedSequenceId)") {
            do {
                let updatedSequence = try ChatSequence(
                    clientId: priorSequenceClientId ?? UUID(),
                    serverId: updatedSequenceId,
                    data: updatedSequenceData)

                // Insert new ChatSequences in reverse order, newest at the top
                DispatchQueue.main.async {
                    self.loadedChatSequences.insert(updatedSequence, at: 0)
                }

                let predicate = #Predicate<OneSequenceViewModel> {
                    $0.sequence.serverId == originalSequenceId
                }
                do {
                    for clientModel in try chatSequenceClientModels.filter(predicate) {
                        DispatchQueue.main.async {
                            clientModel.sequence = updatedSequence
                        }
                    }
                }

                return updatedSequence
            }
            catch {
                print("[ERROR] Failed to ChatSyncService.replaceSequenceById(\(String(describing: originalSequenceId)), with: \(updatedSequenceId))")
            }
        }
        else {
            print("[ERROR] Failed to GET ChatSequence\(updatedSequenceId)")
        }

        return nil
    }
}
