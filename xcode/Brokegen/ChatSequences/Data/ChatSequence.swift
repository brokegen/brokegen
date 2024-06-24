import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

typealias ChatSequenceServerID = Int

class ChatSequence: Identifiable {
    let id: UUID
    var serverId: ChatSequenceServerID?
    let humanDesc: String?
    let userPinned: Bool

    let generatedAt: Date?

    /// This list is not synced with anything on the server; this is intentional.
    /// Only messages that are first uploaded to the server, and recorded with ChatSequence nodes, will get processed.
    ///
    /// Put a different way, this list is entirely a client-side construction/interpretation of messages returned to us.
    ///
    var messages: [Message] = []
    let inferenceModelId: FoundationModelRecordID?

    let isLeafSequence: Bool?
    let parentSequences: [ChatSequenceServerID]?

    static func fromJsonDict(serverId: ChatSequenceServerID? = nil, json sequenceJson: JSON) throws -> ChatSequence {
        var messageBuilder: [Message] = []
        for messageJson in sequenceJson["messages"].arrayValue {
            let message = Message(
                role: messageJson["role"].stringValue,
                content: messageJson["content"].stringValue,
                createdAt: messageJson["created_at"].isoDateValue
            )
            message.serverId = messageJson["id"].int

            messageBuilder.append(message)
        }

        return ChatSequence(
            serverId: serverId,
            humanDesc: sequenceJson["human_desc"].string,
            userPinned: sequenceJson["user_pinned"].bool ?? false,
            generatedAt: sequenceJson["generated_at"].isoDate,
            messages: messageBuilder,
            inferenceModelId: sequenceJson["inference_model_id"].int,
            isLeafSequence: sequenceJson["is_leaf_sequence"].bool,
            parentSequences: sequenceJson["parent_sequences"].array as? [ChatSequenceServerID]
        )
    }

    init(
        clientId: UUID = UUID(),
        serverId: ChatSequenceServerID?,
        humanDesc: String? = nil,
        userPinned: Bool = false,
        generatedAt: Date? = nil,
        messages: [Message],
        inferenceModelId: FoundationModelRecordID? = nil,
        isLeafSequence: Bool? = nil,
        parentSequences: [ChatSequenceServerID]? = nil
    ) {
        self.id = clientId
        self.serverId = serverId
        self.humanDesc = humanDesc
        self.userPinned = userPinned
        self.generatedAt = generatedAt
        self.messages = messages
        self.inferenceModelId = inferenceModelId
        self.isLeafSequence = isLeafSequence
        self.parentSequences = parentSequences
    }

    func replaceId(_ newClientId: UUID) -> ChatSequence {
        return ChatSequence(
            clientId: newClientId,
            serverId: self.serverId,
            humanDesc: self.humanDesc,
            userPinned: self.userPinned,
            generatedAt: self.generatedAt,
            messages: self.messages,
            inferenceModelId: self.inferenceModelId,
            isLeafSequence: self.isLeafSequence,
            parentSequences: self.parentSequences
        )
    }

    func replaceHumanDesc(desc humanDesc: String?) -> ChatSequence {
        return ChatSequence(
            clientId: self.id,
            serverId: self.serverId,
            humanDesc: humanDesc,
            userPinned: self.userPinned,
            generatedAt: self.generatedAt,
            messages: self.messages,
            inferenceModelId: self.inferenceModelId,
            isLeafSequence: self.isLeafSequence,
            parentSequences: self.parentSequences
        )
    }

    func replaceUserPinned(pinned userPinned: Bool) -> ChatSequence {
        return ChatSequence(
            clientId: self.id,
            serverId: self.serverId,
            humanDesc: self.humanDesc,
            userPinned: userPinned,
            generatedAt: self.generatedAt,
            messages: self.messages,
            inferenceModelId: self.inferenceModelId,
            isLeafSequence: self.isLeafSequence,
            parentSequences: self.parentSequences
        )
    }

    var lastMessageDate: Date? {
        guard !messages.isEmpty else { return nil }
        return messages.last!.createdAt
    }

    func displayServerId() -> String {
        if serverId == nil {
            return "[uncommitted ChatSequence]"
        }

        return "ChatSequence#\(serverId!)"
    }

    func displayRecognizableDesc(
        displayLimit: Int? = 140
    ) -> String {
        if serverId == nil {
            return displayHumanDesc(displayLimit: displayLimit)
        }
        else {
            if !(humanDesc ?? "").isEmpty {
                let fullString = "\(displayServerId()): \(humanDesc!)"
                if displayLimit != nil {
                    return String(fullString.prefix(displayLimit!))
                }
                else {
                    return fullString
                }
            }
            else {
                return displayServerId()
            }
        }
    }

    func displayHumanDesc(
        displayLimit: Int? = nil
    ) -> String {
        if !(humanDesc ?? "").isEmpty {
            if displayLimit != nil {
                return String(humanDesc!.prefix(displayLimit!))
            }
            else {
                return humanDesc!
            }
        }

        return displayServerId()
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
            userPinned: false,
            currentMessage: messageId,
            generatedAt: Date.now,
            generationComplete: true
        )
        let encodedParams: Data = try jsonEncoder.encode(params)

        let responseData: Data? = try? await postDataBlocking(encodedParams, endpoint: "/sequences")
        guard responseData != nil else { throw ChatSyncServiceError.invalidResponseContentReturned }

        return JSON(responseData!)["sequence_id"].int
    }

    func doFetchRecents(
        lookback: TimeInterval?,
        limit: Int?,
        includeUserPinned: Bool?,
        includeLeafSequences: Bool?,
        includeAll: Bool?
    ) async throws {
        var endpointMaker = "/sequences/.recent/as-json?"

        if lookback != nil {
            endpointMaker += "&lookback=\(lookback!)"
        }
        if limit != nil {
            endpointMaker += "&limit=\(limit!)"
        }
        if includeUserPinned != nil {
            endpointMaker += "&include_user_pinned=\(includeUserPinned!)"
        }
        if includeLeafSequences != nil {
            endpointMaker += "&include_leaf_sequences=\(includeLeafSequences!)"
        }
        if includeAll != nil {
            endpointMaker += "&include_all=\(includeAll!)"
        }

        let sequencesData = try await getDataBlocking(endpointMaker)
        guard sequencesData != nil else { throw ChatSyncServiceError.noResponseContentReturned }

        for oneSequenceData in JSON(sequencesData!)["sequences"].arrayValue {
            if let oneSequence = try? ChatSequence.fromJsonDict(
                serverId: oneSequenceData["id"].int,
                json: oneSequenceData
            ) {
                DispatchQueue.main.async {
                    self.updateSequence(withSameId: oneSequence)
                }
            }
        }
    }

    public func doFetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        if let entireSequence = try await getDataBlocking("/sequences/\(sequenceId)/as-messages") {
            return try ChatSequence.fromJsonDict(serverId: sequenceId, json: JSON(entireSequence))
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

        if let updatedSequenceData = try? await getDataBlocking("/sequences/\(updatedSequenceId)/as-messages") {
            do {
                let updatedSequence = try ChatSequence.fromJsonDict(
                    serverId: updatedSequenceId,
                    json: JSON(updatedSequenceData))

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
