
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("Content")
struct ContentTests {
    @Test("text content round-trips")
    func textRoundTrip() throws {
        let value: Content = .text("Hello, world.")
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
    }

    @Test("text content encodes with type=text discriminator")
    func textWireShape() throws {
        let value: Content = .text("hi")
        let data = try JSONEncoder().encode(value)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"type\":\"text\""))
        #expect(raw.contains("\"text\":\"hi\""))
    }

    @Test("image content round-trips with base64 source")
    func imageBase64RoundTrip() throws {
        let value: Content = .image(
            ImageSource(
                type: "base64",
                mediaType: "image/png",
                data: "iVBORw0KGgo=",
                url: nil
            )
        )
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
    }

    @Test("image content uses snake_case media_type on the wire")
    func imageSnakeCase() throws {
        let value: Content = .image(
            ImageSource(type: "base64", mediaType: "image/jpeg", data: "AAAA")
        )
        let data = try JSONEncoder().encode(value)
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Foundation's JSONEncoder escapes `/` as `\/`, so check the key
        // and the (escaped) value separately rather than asserting on the
        // exact unescaped string.
        #expect(raw.contains("\"media_type\""))
        #expect(raw.contains("image") && raw.contains("jpeg"))
    }

    @Test("tool_use round-trips with JSONValue input")
    func toolUseRoundTrip() throws {
        let value: Content = .toolUse(
            id: "toolu_01",
            name: "read",
            input: .object(["path": .string("README.md")])
        )
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
    }

    @Test("tool_result with isError=true emits is_error on the wire")
    func toolResultEmitsIsErrorWhenTrue() throws {
        let value: Content = .toolResult(
            toolUseId: "toolu_01",
            content: [.text("permission denied")],
            isError: true
        )
        let data = try JSONEncoder().encode(value)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"is_error\":true"))
        let restored = try JSONDecoder().decode(Content.self, from: data)
        #expect(restored == value)
    }

    @Test("tool_result with isError=false omits is_error on the wire")
    func toolResultOmitsIsErrorWhenFalse() throws {
        let value: Content = .toolResult(
            toolUseId: "toolu_01",
            content: [.text("ok")],
            isError: false
        )
        let data = try JSONEncoder().encode(value)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(!raw.contains("is_error"))
        let restored = try JSONDecoder().decode(Content.self, from: data)
        // Decoded value still equates as isError=false (default).
        #expect(restored == value)
    }

    @Test("thinking content with signature round-trips")
    func thinkingRoundTrip() throws {
        let value: Content = .thinking(
            text: "Let me consider the trade-offs.",
            signature: "sig-abc"
        )
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
    }

    @Test("thinking content without signature round-trips")
    func thinkingNoSignature() throws {
        let value: Content = .thinking(text: "...", signature: nil)
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
    }

    @Test("unknown content type fails to decode")
    func unknownType() {
        let raw = #"{"type":"unknown_block","payload":"x"}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Content.self, from: raw)
        }
    }
}
