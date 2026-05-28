
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("StreamEvent")
struct StreamEventTests {
    @Test("messageStop decodes with no payload beyond type")
    func messageStopDecode() throws {
        let raw = #"{"type":"message_stop"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(StreamEvent.self, from: raw)
        #expect(event == .messageStop)
    }

    @Test("ping decodes with no payload beyond type")
    func pingDecode() throws {
        let raw = #"{"type":"ping"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(StreamEvent.self, from: raw)
        #expect(event == .ping)
    }

    @Test("content_block_delta carries index and delta payload")
    func contentBlockDeltaDecode() throws {
        let raw = #"""
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
        """#.data(using: .utf8)!
        let event = try JSONDecoder().decode(StreamEvent.self, from: raw)
        guard case .contentBlockDelta(let payload) = event else {
            Issue.record("Expected contentBlockDelta, got \(event)")
            return
        }
        #expect(payload.index == 0)
        #expect(payload.delta.objectValue?["type"]?.stringValue == "text_delta")
    }

    @Test("content_block_stop decodes with index")
    func contentBlockStopDecode() throws {
        let raw = #"{"type":"content_block_stop","index":2}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(StreamEvent.self, from: raw)
        guard case .contentBlockStop(let payload) = event else {
            Issue.record("Expected contentBlockStop, got \(event)")
            return
        }
        #expect(payload.index == 2)
    }

    @Test("error decodes type and message from the nested error object")
    func errorDecode() throws {
        // Canonical Anthropic wire shape — the body lives under a nested
        // `error` object so it doesn't collide with the event-level `type`
        // discriminator.
        let raw = #"""
        {"type":"error","error":{"type":"overloaded_error","message":"slow down"}}
        """#.data(using: .utf8)!
        let event = try JSONDecoder().decode(StreamEvent.self, from: raw)
        guard case .error(let payload) = event else {
            Issue.record("Expected error event, got \(event)")
            return
        }
        #expect(payload.type == "overloaded_error")
        #expect(payload.message == "slow down")
    }

    @Test("error round-trips via the nested wire shape")
    func errorRoundTrip() throws {
        let event = StreamEvent.error(
            StreamErrorPayload(type: "rate_limit_error", message: "too many")
        )
        let data = try JSONEncoder().encode(event)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"error\""))
        #expect(raw.contains("\"rate_limit_error\""))
        let restored = try JSONDecoder().decode(StreamEvent.self, from: data)
        #expect(restored == event)
    }

    @Test("unknown event type fails to decode")
    func unknownType() {
        let raw = #"{"type":"surprise"}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(StreamEvent.self, from: raw)
        }
    }

    @Test("message_start round-trips with opaque message payload")
    func messageStartRoundTrip() throws {
        let event = StreamEvent.messageStart(
            MessageStartPayload(
                message: .object([
                    "id": .string("msg_abc"),
                    "model": .string("claude-sonnet-4-6"),
                    "role": .string("assistant"),
                ])
            )
        )
        let data = try JSONEncoder().encode(event)
        let restored = try JSONDecoder().decode(StreamEvent.self, from: data)
        guard case .messageStart(let payload) = restored else {
            Issue.record("Expected messageStart, got \(restored)")
            return
        }
        #expect(payload.message.objectValue?["id"]?.stringValue == "msg_abc")
    }

    @Test("messageDelta round-trips with delta and usage")
    func messageDeltaRoundTrip() throws {
        let event = StreamEvent.messageDelta(
            MessageDeltaPayload(
                delta: .object(["stop_reason": .string("end_turn")]),
                usage: .object([
                    "input_tokens": .int(120),
                    "output_tokens": .int(35),
                ])
            )
        )
        let data = try JSONEncoder().encode(event)
        let restored = try JSONDecoder().decode(StreamEvent.self, from: data)
        guard case .messageDelta(let payload) = restored else {
            Issue.record("Expected messageDelta, got \(restored)")
            return
        }
        #expect(payload.delta.objectValue?["stop_reason"]?.stringValue == "end_turn")
        #expect(payload.usage?.objectValue?["output_tokens"]?.intValue == 35)
    }
}
