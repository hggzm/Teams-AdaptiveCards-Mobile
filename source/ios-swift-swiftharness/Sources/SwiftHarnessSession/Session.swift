// SwiftHarnessSession — Session
//
// Persisted session bundle. JSON wire shape mirrors the upstream Rust
// `SessionState` struct exactly so `.sessions/<id>.json` bundles
// round-trip byte-identically between swiftharness and the upstream
// Rust workspace.
//
// Field omission rules (matching upstream `#[serde(...)]` attributes):
//   - `label`  is omitted entirely when nil (`skip_serializing_if =
//     "Option::is_none"`).
//   - `pinned` is omitted entirely when false (`skip_serializing_if =
//     "is_false"`).
//
// All other fields are always serialized, even at their default
// values, so newly-created sessions have a stable on-disk shape.

import Foundation
import SwiftHarnessCore

/// Persisted state of a single session.
public struct Session: Equatable, Sendable {
    /// Stable identifier for this session.
    public var sessionId: SessionId

    /// Wall-clock milliseconds-since-epoch at which this session was
    /// first created. Never updated after creation.
    public var createdAtMs: Int64

    /// Wall-clock milliseconds-since-epoch at which a real interaction
    /// last touched this session. Bumped on `appendTurn(...)` and on
    /// any other prompt-affecting change; deliberately NOT bumped by
    /// label / pin / unlabel / retag / unpin operations (matching the
    /// upstream determinism rule).
    public var updatedAtMs: Int64

    /// User prompts captured in this session, in arrival order.
    public var messages: [Prompt]

    /// Running input / output token tally.
    public var usage: UsageSummary

    /// Optional human-friendly label. `nil` means "no label".
    public var label: String?

    /// `true` if this session is pinned. Pinned sessions are
    /// preserved by `prune(...)` regardless of the keep budget.
    public var pinned: Bool

    /// Build a `Session`. All fields except `sessionId`, `createdAtMs`,
    /// and `updatedAtMs` default to "empty / unset".
    public init(
        sessionId: SessionId,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        messages: [Prompt] = [],
        usage: UsageSummary = UsageSummary(),
        label: String? = nil,
        pinned: Bool = false
    ) {
        self.sessionId = sessionId
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.messages = messages
        self.usage = usage
        self.label = label
        self.pinned = pinned
    }
}

extension Session: Codable {
    // Snake_case keys to match the upstream wire format.
    private enum CodingKeys: String, CodingKey {
        case sessionId   = "session_id"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case messages
        case usage
        case label
        case pinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId   = try c.decode(SessionId.self,         forKey: .sessionId)
        self.createdAtMs = try c.decode(Int64.self,             forKey: .createdAtMs)
        self.updatedAtMs = try c.decode(Int64.self,             forKey: .updatedAtMs)
        self.messages    = try c.decodeIfPresent([Prompt].self, forKey: .messages) ?? []
        self.usage       = try c.decodeIfPresent(UsageSummary.self, forKey: .usage)
                              ?? UsageSummary()
        self.label       = try c.decodeIfPresent(String.self,   forKey: .label)
        self.pinned      = try c.decodeIfPresent(Bool.self,     forKey: .pinned) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.sessionId,   forKey: .sessionId)
        try c.encode(self.createdAtMs, forKey: .createdAtMs)
        try c.encode(self.updatedAtMs, forKey: .updatedAtMs)
        try c.encode(self.messages,    forKey: .messages)
        try c.encode(self.usage,       forKey: .usage)
        // Omit `label` entirely when nil and `pinned` entirely when
        // false, matching upstream `#[serde(skip_serializing_if = ...)]`.
        if let label = self.label {
            try c.encode(label, forKey: .label)
        }
        if self.pinned {
            try c.encode(true, forKey: .pinned)
        }
    }
}
