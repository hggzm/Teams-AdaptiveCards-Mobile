
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("ToolDef")
struct ToolDefTests {
    @Test("ToolDef serializes input_schema using snake_case")
    func snakeCaseWire() throws {
        let toolDef = ToolDef(
            name: "read",
            description: "Read a file.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                ]),
            ])
        )
        let data = try JSONEncoder().encode(toolDef)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"input_schema\""))
        #expect(!raw.contains("inputSchema"))
    }

    @Test("ToolDef round-trips with non-trivial schema")
    func roundTrip() throws {
        let toolDef = ToolDef(
            name: "bash",
            description: "Run a shell command with a timeout.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object(["type": .string("string")]),
                    "timeout": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("command")]),
            ])
        )
        let restored = try TestHelpers.roundTrip(toolDef)
        #expect(restored == toolDef)
    }
}
