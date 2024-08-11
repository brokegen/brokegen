import Alamofire
import Combine
import Foundation
import SwiftData
import SwiftyJSON

typealias ChatSequenceServerID = Int

class ChatSequence: Identifiable {
    let id: UUID
    let serverId: ChatSequenceServerID
    let humanDesc: String?
    let userPinned: Bool

    let generatedAt: Date?

    /// This list is not synced with anything on the server; this is intentional.
    /// Only messages that are first uploaded to the server, and recorded with ChatSequence nodes, will get processed.
    ///
    /// Put a different way, this list is entirely a client-side construction/interpretation of messages returned to us.
    ///
    var messages: [MessageLike] = []
    let inferenceModelId: FoundationModelRecordID?

    let isLeafSequence: Bool?
    let parentSequences: [ChatSequenceServerID]?

    static func fromJsonDict(serverId: ChatSequenceServerID, json sequenceJson: JSON) throws -> ChatSequence {
        var messageBuilder: [MessageLike] = []
        for messageJson in sequenceJson["messages"].arrayValue {
            if messageJson["message_id"].int == nil {
                let message: TemporaryChatMessage = TemporaryChatMessage(
                    role: messageJson["role"].stringValue,
                    content: messageJson["content"].stringValue,
                    createdAt: messageJson["created_at"].isoDateValue
                )

                messageBuilder.append(.temporary(message, .serverInfo))
            }
            else {
                let message: ChatMessage = ChatMessage(
                    serverId: messageJson["message_id"].intValue,
                    hostSequenceId: messageJson["sequence_id"].intValue,
                    role: messageJson["role"].stringValue,
                    content: messageJson["content"].stringValue,
                    createdAt: messageJson["created_at"].isoDateValue
                )

                messageBuilder.append(.stored(message))
            }
        }

        var parentsBuilder: [ChatSequenceServerID] = []
        for parentSequenceId in sequenceJson["parent_sequences"].arrayValue {
            if let sequenceId = parentSequenceId.int {
                parentsBuilder.append(sequenceId)
            }
        }

        return ChatSequence(
            serverId: serverId,
            humanDesc: sequenceJson["human_desc"].string,
            userPinned: sequenceJson["user_pinned"].bool ?? false,
            generatedAt: sequenceJson["generated_at"].isoDate,
            messages: messageBuilder,
            inferenceModelId: sequenceJson["inference_model_id"].int,
            isLeafSequence: sequenceJson["is_leaf_sequence"].bool,
            parentSequences: parentsBuilder
        )
    }

    init(
        clientId: UUID = UUID(),
        serverId: ChatSequenceServerID,
        humanDesc: String? = nil,
        userPinned: Bool = false,
        generatedAt: Date? = nil,
        messages: [MessageLike],
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

    func replaceServerId(_ newServerId: ChatSequenceServerID) -> ChatSequence {
        // Manually update our local list of "parents", as needed
        var parentSequences = self.parentSequences
        parentSequences?.insert(newServerId, at: 0)

        return ChatSequence(
            clientId: self.id,
            serverId: newServerId,
            humanDesc: self.humanDesc,
            userPinned: self.userPinned,
            generatedAt: self.generatedAt,
            messages: self.messages,
            inferenceModelId: self.inferenceModelId,
            isLeafSequence: self.isLeafSequence,
            parentSequences: parentSequences
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

    func replaceIsLeaf(_ isLeafSequence: Bool) -> ChatSequence {
        return ChatSequence(
            clientId: self.id,
            serverId: self.serverId,
            humanDesc: self.humanDesc,
            userPinned: userPinned,
            generatedAt: self.generatedAt,
            messages: self.messages,
            inferenceModelId: self.inferenceModelId,
            isLeafSequence: isLeafSequence,
            parentSequences: self.parentSequences
        )
    }

    var updatedAt: Date? {
        var currentLatestDate: Date? = nil

        for message in messages {
            if message.createdAt == nil {
                continue
            }

            if currentLatestDate == nil {
                currentLatestDate = message.createdAt
                continue
            }

            /// We have to check more than the latest message, because if we re-use a ChatMessage, we pick up its createdAt.
            /// However, since messages are generally in sequence, we can go back until we hit the first "assistant" message:
            ///
            /// - "assistant" messages are virtually always freshly-rendered, so we can just check up until that message.
            /// - And since this is only used for UI rendering purposes, it doesn't have to be _that_ exact.
            ///
            if currentLatestDate! > message.createdAt! {
                return currentLatestDate
            }

            currentLatestDate = max(currentLatestDate!, message.createdAt!)
        }

        // Also check other timestamps we have access to
        if self.generatedAt != nil {
            if currentLatestDate == nil {
                currentLatestDate = self.generatedAt
            }
            else {
                currentLatestDate = max(currentLatestDate!, self.generatedAt!)
            }
        }

        return currentLatestDate
    }
}

extension ChatSequence: CustomStringConvertible {
    var description: String {
        return self.displayRecognizableDesc(replaceNewlines: true)
    }

    func displayServerId() -> String {
        return "ChatSequence#\(serverId)"
    }

    func displayRecognizableDesc(
        displayLimit: Int? = 140,
        replaceNewlines: Bool = false
    ) -> String {
        if !(humanDesc ?? "").isEmpty {
            var fullString = "\(displayServerId()): \(humanDesc!)"
            if replaceNewlines {
                fullString = fullString.replacingOccurrences(of: "\n", with: "\\n")
            }

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
        return lhs.serverId == rhs.serverId
    }
}

extension ChatSequence: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(serverId)
    }
}

extension ChatSequence: Comparable {
    static func < (lhs: ChatSequence, rhs: ChatSequence) -> Bool {
        if lhs.generatedAt == nil {
            return false
        }
        if rhs.generatedAt == nil {
            return true
        }

        if lhs.generatedAt == rhs.generatedAt {
            return lhs.parentSequences?.count ?? -1 > rhs.parentSequences?.count ?? -1
        }

        return lhs.generatedAt! > rhs.generatedAt!
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

    func doAppendMessage(sequence: ChatSequence, messageId: ChatMessageServerID) async throws -> ChatSequenceServerID? {
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
            humanDesc: sequence.displayHumanDesc().isEmpty ? nil : sequence.humanDesc,
            userPinned: sequence.userPinned,
            currentMessage: messageId,
            parentSequence: sequence.serverId,
            generatedAt: Date.now,
            generationComplete: true
        )
        let encodedParams: Data = try jsonEncoder.encode(params)

        let responseData: Data? = try? await postDataBlocking(encodedParams, endpoint: "/sequences")
        guard responseData != nil else { throw ChatSyncServiceError.invalidResponseContentReturned }

        let responseSequenceId: ChatSequenceServerID? = JSON(responseData!)["sequence_id"].int
        guard responseSequenceId != nil else { throw ChatSyncServiceError.invalidResponseContentReturned }

        // Now that we're done, un-pin the parent sequence, if needed
        pin(sequenceId: sequence.serverId, pinned: false)

        return responseSequenceId
    }

    public func doFetchChatSequenceDetails(_ sequenceId: ChatSequenceServerID) async throws -> ChatSequence? {
        if let entireSequence = try await getDataBlocking("/sequences/\(sequenceId)/as-json") {
            return try ChatSequence.fromJsonDict(serverId: sequenceId, json: JSON(entireSequence))
        }
        else {
            throw ChatSyncServiceError.noResponseContentReturned
        }
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

        let sequenceUpdates: [ChatSequence] = {
            var sequenceUpdates: [ChatSequence] = []

            for oneSequenceData in JSON(sequencesData!)["sequences"].arrayValue {
                if let oneSequence = try? ChatSequence.fromJsonDict(
                    serverId: oneSequenceData["id"].int!,
                    json: oneSequenceData
                ) {
                    sequenceUpdates.append(oneSequence)
                }
            }

            return sequenceUpdates
        }()

        DispatchQueue.main.async {
            let startTime = Date.now

            for oneSequence in sequenceUpdates {
                self.updateSequence(withSameId: oneSequence, disablePublish: true)
            }

            self.objectWillChange.send()

            let elapsedMsec = Date.now.timeIntervalSince(startTime) * 1000
            if elapsedMsec > 8.333 {
                print("[TRACE] DefaultChatSyncService.fetchRecents() update time: \(String(format: "%.3f", elapsedMsec)) msec for \(sequenceUpdates.count) sequences")
            }
        }
    }
}
