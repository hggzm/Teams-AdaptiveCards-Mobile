// SSEParser — turn a byte stream of Server-Sent Events into typed
// `StreamEvent` values.
//
// Layered on top of `SSELineSplitter`. The line splitter handles BOM
// removal, line-terminator normalization, and partial UTF-8 tails; the
// parser interprets the resulting field lines per the SSE spec and the
// Anthropic Messages API conventions, then JSON-decodes the accumulated
// `data:` payload into a `StreamEvent`.
//
// Spec references:
//   - https://html.spec.whatwg.org/multipage/server-sent-events.html
//   - Anthropic Messages API streaming format (event names map directly
//     to the StreamEvent variants in SwiftPiCore).

import Foundation
import SwiftPiCore

/// Output of a parser feed: every fully-decoded `StreamEvent` and every
/// recoverable error encountered while decoding `data:` payloads. The
/// parser deliberately does NOT abort the stream on per-event JSON
/// failures — those are surfaced as `errors` so the caller can log or
/// surface them, while subsequent events keep flowing.
public struct SSEParseOutput: Sendable, Equatable {
    public var events: [StreamEvent]
    public var errors: [SwiftPiError]

    public init(events: [StreamEvent] = [], errors: [SwiftPiError] = []) {
        self.events = events
        self.errors = errors
    }

    public var isEmpty: Bool {
        events.isEmpty && errors.isEmpty
    }

    public static func + (lhs: SSEParseOutput, rhs: SSEParseOutput) -> SSEParseOutput {
        SSEParseOutput(events: lhs.events + rhs.events, errors: lhs.errors + rhs.errors)
    }

    public static func += (lhs: inout SSEParseOutput, rhs: SSEParseOutput) {
        lhs.events.append(contentsOf: rhs.events)
        lhs.errors.append(contentsOf: rhs.errors)
    }
}

/// Incremental SSE parser. Feed bytes with `feed(_:)`; call `finish()`
/// at end-of-stream to flush any trailing event that wasn't followed by
/// a blank line.
public struct SSEParser: Sendable {
    private var splitter = SSELineSplitter()

    /// The event-name buffer accumulated from `event:` field lines.
    /// Anthropic sends this redundantly with the JSON `type` field, but
    /// we honor whichever the spec mandates: the JSON discriminator wins
    /// at decode time, the event name is only used in diagnostics.
    private var eventName: String = ""

    /// Buffered `data:` field values, joined with `\n` per the SSE spec
    /// when an event is dispatched.
    private var dataLines: [String] = []

    public init() {}

    // MARK: - Feeding

    /// Feed a chunk of raw bytes from the network. Returns the events
    /// (and recoverable errors) produced by completing any whole events
    /// inside this chunk.
    public mutating func feed(_ chunk: [UInt8]) -> SSEParseOutput {
        var output = SSEParseOutput()
        for line in splitter.feed(chunk) {
            handleLine(line, into: &output)
        }
        return output
    }

    /// Convenience overload for `Data` chunks.
    public mutating func feed(_ chunk: Data) -> SSEParseOutput {
        feed(Array(chunk))
    }

    /// End-of-stream flush. Drains any partial trailing line and
    /// dispatches a pending event if one had accumulated without a
    /// trailing blank line. (Conforming servers always send a blank
    /// line, but real network closures sometimes truncate the stream
    /// right after the last `data:`.)
    public mutating func finish() -> SSEParseOutput {
        var output = SSEParseOutput()
        for line in splitter.finish() {
            handleLine(line, into: &output)
        }
        // Dispatch a still-pending event if any `data:` lines accumulated.
        dispatchPending(into: &output)
        return output
    }

    // MARK: - One-shot helpers

    /// Parse a complete payload in one call. Convenience for tests and
    /// for callers that already buffered the whole response.
    public static func parse(_ data: Data) -> SSEParseOutput {
        var parser = SSEParser()
        var output = parser.feed(data)
        output += parser.finish()
        return output
    }

    /// Parse a UTF-8 string. Equivalent to `parse(_:)` of its bytes.
    public static func parse(_ text: String) -> SSEParseOutput {
        parse(Data(text.utf8))
    }

    // MARK: - Internal field/dispatch handling

    private mutating func handleLine(_ line: String, into output: inout SSEParseOutput) {
        // SSE spec: an empty line dispatches the buffered event (if any).
        if line.isEmpty {
            dispatchPending(into: &output)
            return
        }
        // SSE spec: lines beginning with U+003A (":") are comments and
        // are ignored. Anthropic uses these for keep-alive (`": ping"`).
        if line.first == ":" {
            return
        }
        // Field line: split on the first colon, strip a single leading
        // space from the value (per SSE spec).
        if let colon = line.firstIndex(of: ":") {
            let field = String(line[..<colon])
            var afterColon = line.index(after: colon)
            if afterColon < line.endIndex, line[afterColon] == " " {
                afterColon = line.index(after: afterColon)
            }
            let value = String(line[afterColon...])
            applyField(field, value: value)
            return
        }
        // Field with no value (whole line is the field name).
        applyField(line, value: "")
    }

    private mutating func applyField(_ field: String, value: String) {
        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        case "id", "retry":
            // Accepted but unused — Anthropic doesn't rely on these.
            break
        default:
            // Unknown field — silently ignored per SSE spec.
            break
        }
    }

    private mutating func dispatchPending(into output: inout SSEParseOutput) {
        defer {
            eventName = ""
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return }

        // SSE spec: data lines are joined with "\n" (no trailing
        // newline, even though the spec describes appending and then
        // stripping one — net effect is the same).
        let payload = dataLines.joined(separator: "\n")

        // Anthropic occasionally streams a `data: [DONE]` sentinel
        // (OpenAI-compatibility carry-over); we tolerate but do not
        // emit anything for it.
        if payload == "[DONE]" {
            return
        }

        let bytes = Data(payload.utf8)
        do {
            let event = try JSONDecoder().decode(StreamEvent.self, from: bytes)
            output.events.append(event)
        } catch let error as DecodingError {
            output.errors.append(.malformedJSON(decodingErrorDescription(error)))
        } catch {
            output.errors.append(.malformedJSON(String(describing: error)))
        }
    }

    private func decodingErrorDescription(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx),
             .keyNotFound(_, let ctx),
             .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}
