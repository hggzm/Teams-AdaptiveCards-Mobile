
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("Message")
struct MessageTests {
    @Test("default initializer sets parent and timestamp to nil")
    func defaultInit() {
        let message = Message(
            id: "msg-1",
            role: .user,
            content: [.text("hello")]
        )
        #expect(message.parent == nil)
        #expect(message.timestamp == nil)
        #expect(message.content.count == 1)
    }

    @Test("Codable round-trip preserves all fields")
    func roundTripFull() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let message = Message(
            id: "msg-2",
            role: .assistant,
            content: [
                .text("Sure."),
                .toolUse(
                    id: "toolu_01",
                    name: "ls",
                    input: .object(["path": .string(".")])
                ),
            ],
            parent: "msg-1",
            timestamp: timestamp
        )
        let restored = try TestHelpers.roundTrip(message)
        #expect(restored.id == "msg-2")
        #expect(restored.role == .assistant)
        #expect(restored.parent == "msg-1")
        #expect(restored.content.count == 2)
    }

    @Test("Codable round-trip without parent or timestamp")
    func roundTripMinimal() throws {
        let message = Message(
            id: "root",
            role: .user,
            content: [.text("first")]
        )
        let restored = try TestHelpers.roundTrip(message)
        #expect(restored == message)
    }
}
