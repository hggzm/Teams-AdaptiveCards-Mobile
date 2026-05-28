// StreamEvent — the discriminated union of events a Provider emits
// while streaming a single assistant turn.
//
// The variants and their wire names match Anthropic's Messages API SSE
// event types. Phase 2's SwiftPiStreaming parser decodes raw bytes into
// these values; Phase 6's agent loop consumes them.
//
// Phase 1 keeps the per-variant payloads intentionally loose
// (`JSONValue`) so that the parser can populate them as soon as it
// lands without churning this type. Phase 4 or later will tighten the
// shape now that downstream code depends on the precise fields.

import Foundation

public enum StreamEvent: Sendable, Equatable {
    /// `message_start` — emitted once at the beginning of a stream with
    /// model and message metadata.
    case messageStart(MessageStartPayload)

    /// `content_block_start` — a new content block (text, tool_use,
    /// thinking, ...) is about to receive deltas.
    case contentBlockStart(ContentBlockStartPayload)

    /// `content_block_delta` — incremental content for the active block.
    case contentBlockDelta(ContentBlockDeltaPayload)

    /// `content_block_stop` — the active content block is finalized.
    case contentBlockStop(ContentBlockStopPayload)

    /// `message_delta` — top-level updates (stop_reason, usage).
    case messageDelta(MessageDeltaPayload)

    /// `message_stop` — the stream is complete. No payload.
    case messageStop

    /// `ping` — keep-alive. Emitted periodically. No payload.
    case ping

    /// `error` — terminal stream error from the provider.
    case error(StreamErrorPayload)
}

// MARK: - Per-variant payloads

public struct MessageStartPayload: Codable, Sendable, Equatable {
    public let message: JSONValue

    public init(message: JSONValue) {
        self.message = message
    }
}

public struct ContentBlockStartPayload: Codable, Sendable, Equatable {
    public let index: Int
    public let contentBlock: JSONValue

    public init(index: Int, contentBlock: JSONValue) {
        self.index = index
        self.contentBlock = contentBlock
    }

    enum CodingKeys: String, CodingKey {
        case index
        case contentBlock = "content_block"
    }
}

public struct ContentBlockDeltaPayload: Codable, Sendable, Equatable {
    public let index: Int
    public let delta: JSONValue

    public init(index: Int, delta: JSONValue) {
        self.index = index
        self.delta = delta
    }
}

public struct ContentBlockStopPayload: Codable, Sendable, Equatable {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }
}

public struct MessageDeltaPayload: Codable, Sendable, Equatable {
    public let delta: JSONValue
    public let usage: JSONValue?

    public init(delta: JSONValue, usage: JSONValue? = nil) {
        self.delta = delta
        self.usage = usage
    }
}

/// Payload of an `error` stream event.
///
/// Anthropic's wire shape nests the actual error under a top-level
/// `error` object so that it doesn't collide with the SSE event's own
/// `type` discriminator:
///
/// ```json
/// {"type":"error","error":{"type":"overloaded_error","message":"slow down"}}
/// ```
///
/// `StreamErrorPayload` reads from that nested object on decode and
/// writes it back out the same way on encode, so callers see a
/// flattened `(type, message)` pair regardless of the underlying wire
/// shape.
public struct StreamErrorPayload: Sendable, Equatable {
    public let type: String
    public let message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}

extension StreamErrorPayload: Codable {
    private enum TopLevelKeys: String, CodingKey {
        case error
    }

    private enum BodyKeys: String, CodingKey {
        case type
        case message
    }

    public init(from decoder: Decoder) throws {
        // Preferred shape: `{ "type": "error", "error": { "type": ..., "message": ... } }`.
        // Fallback shape (test fixtures, ad-hoc payloads): the body fields
        // appear at the top level alongside the `type:"error"` discriminator.
        if let top = try? decoder.container(keyedBy: TopLevelKeys.self),
           top.contains(.error),
           let nested = try? top.nestedContainer(keyedBy: BodyKeys.self, forKey: .error)
        {
            self.type = try nested.decode(String.self, forKey: .type)
            self.message = try nested.decode(String.self, forKey: .message)
            return
        }
        let body = try decoder.container(keyedBy: BodyKeys.self)
        self.type = try body.decode(String.self, forKey: .type)
        self.message = try body.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var top = encoder.container(keyedBy: TopLevelKeys.self)
        var nested = top.nestedContainer(keyedBy: BodyKeys.self, forKey: .error)
        try nested.encode(type, forKey: .type)
        try nested.encode(message, forKey: .message)
    }
}

// MARK: - Codable

extension StreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum EventType: String {
        case messageStart = "message_start"
        case contentBlockStart = "content_block_start"
        case contentBlockDelta = "content_block_delta"
        case contentBlockStop = "content_block_stop"
        case messageDelta = "message_delta"
        case messageStop = "message_stop"
        case ping
        case error
    }

    public init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try typeContainer.decode(String.self, forKey: .type)
        guard let kind = EventType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: typeContainer,
                debugDescription: "Unknown stream event type: \(rawType)"
            )
        }
        switch kind {
        case .messageStart:
            self = .messageStart(try MessageStartPayload(from: decoder))
        case .contentBlockStart:
            self = .contentBlockStart(try ContentBlockStartPayload(from: decoder))
        case .contentBlockDelta:
            self = .contentBlockDelta(try ContentBlockDeltaPayload(from: decoder))
        case .contentBlockStop:
            self = .contentBlockStop(try ContentBlockStopPayload(from: decoder))
        case .messageDelta:
            self = .messageDelta(try MessageDeltaPayload(from: decoder))
        case .messageStop:
            self = .messageStop
        case .ping:
            self = .ping
        case .error:
            self = .error(try StreamErrorPayload(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .messageStart(let payload):
            try payload.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.messageStart.rawValue, forKey: .type)
        case .contentBlockStart(let payload):
            try payload.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.contentBlockStart.rawValue, forKey: .type)
        case .contentBlockDelta(let payload):
            try payload.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.contentBlockDelta.rawValue, forKey: .type)
        case .contentBlockStop(let payload):
            try payload.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.contentBlockStop.rawValue, forKey: .type)
        case .messageDelta(let payload):
            try payload.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.messageDelta.rawValue, forKey: .type)
        case .messageStop:
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.messageStop.rawValue, forKey: .type)
        case .ping:
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.ping.rawValue, forKey: .type)
        case .error(let payload):
            try payload.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(EventType.error.rawValue, forKey: .type)
        }
    }
}
