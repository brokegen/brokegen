import SwiftyJSON
import XCTest

@testable import Brokegen


final class ChatMessageTests: XCTestCase {
    func testEncode() throws {
        let tempMessage = TemporaryChatMessage(
            role: "user",
            content: "user message 1"
        )

        let encodedData = try tempMessage.asJsonData()
    }

    func testDecode() throws {
        let jsonData = """
{
    "id": 86204401,
    "role": "assistant",
    "content": "assistant message 3",
    "created_at": "2024-06-10T01:45:43.723648"
}
"""
        let encodedData = Data(jsonData.utf8)

        var referenceDateComponents = DateComponents()
        referenceDateComponents.year = 2024
        referenceDateComponents.month = 6
        referenceDateComponents.day = 10
        referenceDateComponents.hour = 1
        referenceDateComponents.minute = 45
        referenceDateComponents.second = 43
        referenceDateComponents.nanosecond = 723_648_000

        let calendar = Calendar(identifier: .iso8601)
        let referenceDate = calendar.date(from: referenceDateComponents)!

        let message = try ChatMessage.fromData(encodedData)
        assert(message.serverId == 86204401)
        assert(message.role == "assistant")
        assert(message.content == "assistant message 3")

        // Due to… Swift, probably, only millisecond accuracy is available.
        assert(message.createdAt.distance(to: referenceDate) < 0.000_001)
    }

    func testEncodeDecode() throws {
        let tempMessage = TemporaryChatMessage(
            role: "user",
            content: "user message 2"
        )

        let encodedData = try tempMessage.asJsonData()

        // Artificially inject a ServerID
        var modifiableData = JSON(encodedData)
        modifiableData["id"] = 221981177
        // Swift? is appending a "Z" at the end of Date strings, but Python doesn't seem to.
        // So just remove it.
        assert(modifiableData["created_at"].string!.last == "Z")
        modifiableData["created_at"].string = String(modifiableData["created_at"].string!.dropLast())
        let encodedModifiableData = try modifiableData.rawData()

        let message = try ChatMessage.fromData(encodedModifiableData)
        assert(message.role == tempMessage.role)
        assert(message.content == tempMessage.content)
        assert(message.createdAt.distance(to: tempMessage.createdAt) < 0.000_001)
    }
}