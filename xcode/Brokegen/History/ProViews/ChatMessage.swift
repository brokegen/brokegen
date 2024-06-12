import Alamofire
import Combine
import Foundation
import SwiftUI
import SwiftyJSON

enum ChatMessageError: Error {
    case expectedUserRole
    case failedDateDecoding
}

enum ChatSyncServiceError: Error {
    case emptyRequestContent
    case noResponseContentReturned
    case invalidResponseContentReturned
}

struct ChatMessage: Equatable, Hashable {
    let serverId: ChatMessageServerID

    let role: String
    let content: String
    let createdAt: Date
}

extension ChatMessage: Identifiable {
    var id: ChatMessageServerID {
        serverId
    }
}

fileprivate let microsecondDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"

    return formatter
}()

extension ChatMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case serverId = "id", role, content, createdAt
    }

    static let jsonDecoder: JSONDecoder = { preserveMicroseconds in
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if preserveMicroseconds {
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self) + "Z"

                /// from https://stackoverflow.com/questions/28016578/
                guard var date = microsecondDateFormatter.date(from: dateString) else { throw ChatMessageError.failedDateDecoding }
                date = Date(
                    timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate)
                )

                if let fractionStart = dateString.range(of: "."),
                   let fractionEnd = dateString.index(fractionStart.lowerBound, offsetBy: 7, limitedBy: dateString.endIndex)
                {
                    // fractionString is a string containing six decimal digits.
                    let fractionString = dateString[fractionStart.lowerBound..<fractionEnd].trimmingPrefix(".")
                    // Directly converting with `Double` introduces errors; `.065005` becomes `.065004`.
                    if let fraction = Int(fractionString) {
                        date.addTimeInterval(Double(fraction) / 1E6)
                    }
                }

                return date
            }
        }
        else {
            decoder.dateDecodingStrategy = .custom { decoder in
                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                let container = try decoder.singleValueContainer()
                if let maybeDate: Date = try dateFormatter.date(from: container.decode(String.self) + "Z") {
                    return maybeDate
                } else {
                    throw ChatMessageError.failedDateDecoding
                }
            }
        }

        return decoder
    }(true)

    static func fromData(_ data: Data) throws -> ChatMessage {
        return try jsonDecoder.decode(ChatMessage.self, from: data)
    }
}

struct TemporaryChatMessage {
    public var role: String
    public var content: String?
    public var createdAt: Date

    init(role: String = "user", content: String? = nil, createdAt: Date = Date.now) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    func assignServerId(
        chatService: ChatSyncService,
        refreshMessageContent: Bool = false
    ) async throws -> ChatMessage? {
        guard role == "user" else { throw ChatMessageError.expectedUserRole }
        guard content != nil else { throw ChatSyncServiceError.emptyRequestContent }
        guard !content!.isEmpty else { throw ChatSyncServiceError.emptyRequestContent }

        let newMessageId = try await chatService.constructChatMessage(from: self)
        if refreshMessageContent {
            if let newMessageData = await chatService.getData("/messages/\(newMessageId)") {
                return try ChatMessage.fromData(newMessageData)
            }
            else {
                throw ChatSyncServiceError.invalidResponseContentReturned
            }
        }
        else {
            return ChatMessage(serverId: newMessageId, role: role, content: content!, createdAt: createdAt)
        }
    }
}

extension TemporaryChatMessage: Encodable {
    func asJsonData(preserveMicroseconds: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        if preserveMicroseconds {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                // Directly converting with `super` introduces errors; `.999500` adds a second.
                var dateString = microsecondDateFormatter.string(
                    from: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
                )

                if let fractionStart = dateString.range(of: "."),
                   let fractionEnd = dateString.index(fractionStart.lowerBound, offsetBy: 7, limitedBy: dateString.endIndex)
                {
                    // Replace the decimal range with the six digit fraction
                    let microseconds = date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)
                    var microsecondsString = String(format: "%.06f", microseconds)
                    microsecondsString.remove(at: microsecondsString.startIndex)

                    let fractionRange = fractionStart.lowerBound..<fractionEnd
                    dateString.replaceSubrange(fractionRange, with: microsecondsString)
                }

                var container = encoder.singleValueContainer()
                try container.encode(microsecondDateFormatter.string(from: date))
            }
        }
        else {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                var container = encoder.singleValueContainer()
                try container.encode(dateFormatter.string(from: date))
            }
        }

        return try encoder.encode(self)
    }
}

extension ChatSyncService {
    func postData(_ httpBody: Data?, endpoint: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                serverBaseURL + endpoint
            ) { urlRequest in
                urlRequest.method = .post
                urlRequest.headers = [
                    "Content-Type": "application/json",
                ]
                urlRequest.httpBody = httpBody
            }
            .response { r in
                switch r.result {
                case .success(let data):
                    if data != nil {
                        continuation.resume(throwing: ChatSyncServiceError.noResponseContentReturned)
                        return
                    }
                    else {
                        continuation.resume(returning: data!)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func doConstructChatMessage(tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID? {
        let httpBody = try tempMessage.asJsonData()
        let responseData = try await postData(httpBody, endpoint: "/messages")

        let messageId: ChatMessageServerID? = JSON(responseData)["message_id"].int
        return messageId
    }

    func constructChatMessage(from tempMessage: TemporaryChatMessage) async throws -> ChatMessageServerID {
        if let maybeMessageId = try await doConstructChatMessage(tempMessage: tempMessage) {
            return maybeMessageId
        }
        else {
            throw ChatSyncServiceError.invalidResponseContentReturned
        }
    }
}
