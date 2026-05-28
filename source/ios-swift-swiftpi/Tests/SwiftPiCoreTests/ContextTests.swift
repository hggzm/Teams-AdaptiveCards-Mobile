
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("Context")
struct ContextTests {
    @Test("default initializer produces an empty context")
    func defaultInit() {
        let context = Context()
        #expect(context.system == nil)
        #expect(context.messages.isEmpty)
        #expect(context.tools.isEmpty)
    }

    @Test("Codable round-trip preserves all fields")
    func roundTripFull() throws {
        let context = Context(
            system: "You are concise.",
            messages: [
                Message(id: "m1", role: .user, content: [.text("hi")]),
                Message(
                    id: "m2",
                    role: .assistant,
                    content: [.text("hello.")],
                    parent: "m1"
                ),
            ],
            tools: [
                ToolDef(
                    name: "ls",
                    description: "List a directory.",
                    inputSchema: .object(["type": .string("object")])
                )
            ]
        )
        let restored = try TestHelpers.roundTrip(context)
        #expect(restored == context)
    }

    @Test("Context round-trips with only a system prompt")
    func systemOnly() throws {
        let context = Context(system: "You are a Swift reviewer.")
        let restored = try TestHelpers.roundTrip(context)
        #expect(restored == context)
    }
}
