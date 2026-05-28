
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("StreamOptions")
struct StreamOptionsTests {
    @Test("required fields are encoded with snake_case keys")
    func snakeCaseWire() throws {
        let options = StreamOptions(
            model: "claude-sonnet-4-6",
            maxTokens: 1024,
            temperature: 0.2,
            thinking: ThinkingConfig(level: .medium),
            stopSequences: ["\n\n"]
        )
        let data = try JSONEncoder().encode(options)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"max_tokens\":1024"))
        #expect(raw.contains("\"stop_sequences\""))
        #expect(raw.contains("\"model\":\"claude-sonnet-4-6\""))
    }

    @Test("Codable round-trip preserves optional fields")
    func roundTripFull() throws {
        let options = StreamOptions(
            model: "claude-opus-4-7",
            maxTokens: 4096,
            temperature: nil,
            thinking: ThinkingConfig(level: .high, budgetTokens: 2048),
            stopSequences: []
        )
        let restored = try TestHelpers.roundTrip(options)
        #expect(restored == options)
    }

    @Test("minimal StreamOptions round-trip")
    func minimal() throws {
        let options = StreamOptions(model: "claude-haiku", maxTokens: 256)
        let restored = try TestHelpers.roundTrip(options)
        #expect(restored == options)
        #expect(restored.temperature == nil)
        #expect(restored.thinking == nil)
        #expect(restored.stopSequences.isEmpty)
    }
}
