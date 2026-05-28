
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiStreaming

// Multi-line Swift strings (`"""..."""`) are sufficient for embedding
// the JSON payloads below — the internal `"` characters are not the
// string delimiter, so no extended `#"..."#` raw-string escape is
// needed. Trailing blank lines in `"""..."""` are preserved as
// `\n` in the resulting Swift string, which mirrors the SSE wire shape
// (events terminated by a blank line).

@Suite("SSEParser — basic events")
struct SSEParserBasicTests {
    @Test("single message_stop event in one chunk")
    func messageStopSingleChunk() {
        let payload = """
        event: message_stop
        data: {"type":"message_stop"}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        #expect(output.events == [.messageStop])
    }

    @Test("single ping event in one chunk")
    func pingSingleChunk() {
        let payload = """
        event: ping
        data: {"type":"ping"}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }

    @Test("multiple events back-to-back parse in order")
    func multipleEvents() {
        let payload = """
        event: ping
        data: {"type":"ping"}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        #expect(output.events.count == 3)
        #expect(output.events.first == .ping)
        #expect(output.events.last == .messageStop)
    }

    @Test("event without data: never dispatches")
    func eventWithoutDataIsSilent() {
        let output = SSEParser.parse("event: ping\n\n")
        #expect(output.events.isEmpty)
        #expect(output.errors.isEmpty)
    }

    @Test("trailing event without final blank line is flushed on finish()")
    func trailingEventFlushedOnFinish() {
        // No trailing blank line; the parser's finish() must still
        // dispatch what was accumulated.
        let payload = "event: message_stop\ndata: {\"type\":\"message_stop\"}"
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        #expect(output.events == [.messageStop])
    }

    @Test("[DONE] sentinel is silently ignored")
    func doneSentinelIgnored() {
        let payload = """
        event: done
        data: [DONE]

        """
        let output = SSEParser.parse(payload)
        #expect(output.events.isEmpty)
        #expect(output.errors.isEmpty)
    }
}

@Suite("SSEParser — content_block_delta")
struct SSEParserContentBlockDeltaTests {
    @Test("content_block_delta decodes index and inner delta")
    func contentBlockDelta() {
        let payload = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        guard let event = output.events.first,
              case .contentBlockDelta(let p) = event
        else {
            Issue.record("Expected contentBlockDelta, got \(output.events)")
            return
        }
        #expect(p.index == 0)
        #expect(p.delta.objectValue?["type"]?.stringValue == "text_delta")
        #expect(p.delta.objectValue?["text"]?.stringValue == "Hello")
    }

    @Test("content_block_start decodes content_block")
    func contentBlockStart() {
        let payload = """
        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        guard let event = output.events.first,
              case .contentBlockStart(let p) = event
        else {
            Issue.record("Expected contentBlockStart")
            return
        }
        #expect(p.index == 2)
        #expect(p.contentBlock.objectValue?["type"]?.stringValue == "text")
    }

    @Test("message_start decodes opaque message payload")
    func messageStart() {
        let payload = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_abc","model":"claude-sonnet-4-6","role":"assistant"}}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        guard let event = output.events.first,
              case .messageStart(let p) = event
        else {
            Issue.record("Expected messageStart")
            return
        }
        #expect(p.message.objectValue?["id"]?.stringValue == "msg_abc")
        #expect(p.message.objectValue?["model"]?.stringValue == "claude-sonnet-4-6")
    }

    @Test("message_delta decodes delta and usage")
    func messageDelta() {
        let payload = """
        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":120,"output_tokens":35}}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        guard let event = output.events.first,
              case .messageDelta(let p) = event
        else {
            Issue.record("Expected messageDelta")
            return
        }
        #expect(p.delta.objectValue?["stop_reason"]?.stringValue == "end_turn")
        #expect(p.usage?.objectValue?["output_tokens"]?.intValue == 35)
    }

    @Test("error event decodes from the nested error object")
    func errorEvent() {
        let payload = """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"slow down"}}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        guard let event = output.events.first,
              case .error(let p) = event
        else {
            Issue.record("Expected error event")
            return
        }
        #expect(p.type == "overloaded_error")
        #expect(p.message == "slow down")
    }
}

@Suite("SSEParser — multi-line data and comments")
struct SSEParserMultilineTests {
    @Test("multiple data: lines are joined with a newline before JSON decode")
    func multiLineDataJoinsWithNewline() {
        // Two `data:` lines forming a single JSON document.
        // The parser must join them with `\n` (per SSE spec) before
        // decoding; with `""` join the JSON would also still decode
        // correctly here, so this test mainly proves we don't accidentally
        // drop one of the data lines.
        let output = SSEParser.parse(
            "event: message_stop\ndata: {\"type\":\ndata: \"message_stop\"}\n\n"
        )
        #expect(output.errors.isEmpty)
        #expect(output.events == [.messageStop])
    }

    @Test("comment lines (starting with ':') are ignored")
    func commentsIgnored() {
        let payload = """
        : ping comment
        event: ping
        data: {"type":"ping"}

        """
        let output = SSEParser.parse(payload)
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }

    @Test("only-comment blocks dispatch no event")
    func onlyCommentsDispatchNothing() {
        let output = SSEParser.parse(": keep-alive\n: another\n\n")
        #expect(output.events.isEmpty)
        #expect(output.errors.isEmpty)
    }

    @Test("data: value with no leading space is preserved")
    func noLeadingSpace() {
        let output = SSEParser.parse("event:ping\ndata:{\"type\":\"ping\"}\n\n")
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }

    @Test("field with no value is tolerated")
    func fieldWithNoValue() {
        let output = SSEParser.parse("retry\nevent: ping\ndata: {\"type\":\"ping\"}\n\n")
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }

    @Test("unknown SSE field is ignored")
    func unknownField() {
        let output = SSEParser.parse(
            "id: 42\nevent: ping\ndata: {\"type\":\"ping\"}\n\n"
        )
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }
}

@Suite("SSEParser — chunking")
struct SSEParserChunkingTests {
    private func feedBytes(_ chunks: [[UInt8]]) -> SSEParseOutput {
        var parser = SSEParser()
        var output = SSEParseOutput()
        for chunk in chunks {
            output += parser.feed(chunk)
        }
        output += parser.finish()
        return output
    }

    @Test("byte-by-byte feeding still parses one event correctly")
    func byteByByte() {
        let payload = "event: ping\ndata: {\"type\":\"ping\"}\n\n"
        let bytes = Array(payload.utf8)
        let chunks = bytes.map { [$0] }
        let output = feedBytes(chunks)
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }

    @Test("partial UTF-8 across chunks decodes intact text in the JSON payload")
    func utf8AcrossChunks() {
        // U+1F600 (😀) is F0 9F 98 80 in UTF-8. Split the boundary
        // inside the JSON text_delta value so both the line splitter
        // AND the JSON decoder must tolerate it.
        let prefix = "event: content_block_delta\ndata: " +
            "{\"type\":\"content_block_delta\",\"index\":0," +
            "\"delta\":{\"type\":\"text_delta\",\"text\":\""
        let suffix = "\"}}\n\n"
        let pre = Array(prefix.utf8) + [0xF0, 0x9F]
        let post: [UInt8] = [0x98, 0x80] + Array(suffix.utf8)
        let output = feedBytes([pre, post])
        #expect(output.errors.isEmpty)
        guard let first = output.events.first,
              case .contentBlockDelta(let p) = first
        else {
            Issue.record("Expected contentBlockDelta")
            return
        }
        #expect(p.delta.objectValue?["text"]?.stringValue == "😀")
    }

    @Test("CRLF line terminators across chunks parse correctly")
    func crlfAcrossChunks() {
        let payload = "event: ping\r\ndata: {\"type\":\"ping\"}\r\n\r\n"
        let bytes = Array(payload.utf8)
        // Split right at the first CR, so the LF arrives in the next chunk.
        let mid = bytes.firstIndex(of: 0x0D) ?? 0
        let output = feedBytes([
            Array(bytes[0..<(mid + 1)]),
            Array(bytes[(mid + 1)...]),
        ])
        #expect(output.errors.isEmpty)
        #expect(output.events == [.ping])
    }
}

@Suite("SSEParser — error tolerance")
struct SSEParserErrorTests {
    @Test("malformed JSON is surfaced as a recoverable error, not a crash")
    func malformedJSON() {
        // Missing closing brace.
        let output = SSEParser.parse(
            "event: message_stop\ndata: {\"type\":\"message_stop\"\n\n"
        )
        #expect(output.events.isEmpty)
        #expect(output.errors.count == 1)
        if case .malformedJSON = output.errors.first {
            // expected
        } else {
            Issue.record("Expected malformedJSON, got \(String(describing: output.errors.first))")
        }
    }

    @Test("unknown event type is surfaced as a recoverable error")
    func unknownEventType() {
        let payload = """
        event: surprise
        data: {"type":"surprise"}

        """
        let output = SSEParser.parse(payload)
        #expect(output.events.isEmpty)
        #expect(output.errors.count == 1)
    }

    @Test("a malformed event between two good events does not break the stream")
    func malformedBetweenGoodEvents() {
        let payload = """
        event: ping
        data: {"type":"ping"}

        event: nonsense
        data: not valid json {

        event: message_stop
        data: {"type":"message_stop"}

        """
        let output = SSEParser.parse(payload)
        #expect(output.events == [.ping, .messageStop])
        #expect(output.errors.count == 1)
    }
}

@Suite("SSEParser — AsyncSSEStream wrapper")
struct AsyncSSEStreamTests {
    /// An AsyncSequence over an in-memory list of byte chunks, modeling
    /// what a real HTTP body would deliver.
    private struct ScriptedBytes: AsyncSequence, Sendable {
        typealias Element = [UInt8]
        let chunks: [[UInt8]]
        struct Iterator: AsyncIteratorProtocol {
            var remaining: [[UInt8]]
            mutating func next() async -> [UInt8]? {
                remaining.isEmpty ? nil : remaining.removeFirst()
            }
        }
        func makeAsyncIterator() -> Iterator { Iterator(remaining: chunks) }
    }

    @Test("scripted byte chunks produce the expected event sequence")
    func happyPath() async throws {
        let payload = """
        event: ping
        data: {"type":"ping"}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let bytes = Array(payload.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: 13).map {
            Array(bytes[$0..<min($0 + 13, bytes.count)])
        }
        let stream = AsyncSSEStream.make(from: ScriptedBytes(chunks: chunks))
        var collected: [StreamEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        #expect(collected.count == 3)
        #expect(collected.first == .ping)
        #expect(collected.last == .messageStop)
    }

    @Test("malformed JSON is surfaced as a synthesized error event by default")
    func malformedSurfacesAsErrorEvent() async throws {
        let payload = """
        event: ping
        data: {"type":"ping"}

        event: oops
        data: {bad json

        """
        let stream = AsyncSSEStream.make(
            from: ScriptedBytes(chunks: [Array(payload.utf8)])
        )
        var collected: [StreamEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        #expect(collected.count == 2)
        #expect(collected.first == .ping)
        if case .error(let p) = collected.last {
            #expect(p.type == "swiftpi_decode_error")
        } else {
            Issue.record("Expected synthesized error event, got \(String(describing: collected.last))")
        }
    }

    @Test("failOnDecodeError = true throws on the first bad event")
    func failOnDecodeError() async {
        let payload = """
        event: oops
        data: {bad json

        """
        let stream = AsyncSSEStream.make(
            from: ScriptedBytes(chunks: [Array(payload.utf8)]),
            failOnDecodeError: true
        )
        var threw = false
        do {
            for try await _ in stream {}
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
