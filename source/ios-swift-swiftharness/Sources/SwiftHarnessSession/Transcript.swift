// SwiftHarnessSession — Transcript
//
// Per-turn record + persisted transcript bundle. JSON wire shape
// mirrors the upstream Rust `TranscriptEntry` and `TranscriptRecord`
// structs exactly so `.sessions/<id>.transcript.json` bundles
// round-trip byte-identically.

import Foundation
import SwiftHarnessCore

/// Single recorded turn inside a transcript.
public struct TranscriptEntry: Equatable, Sendable, Codable {
    /// Zero-based position of this turn in the transcript.
    public var turnIndex: TurnIndex

    /// User prompt that drove this turn.
    public var prompt: Prompt

    public init(turnIndex: TurnIndex, prompt: Prompt) {
        self.turnIndex = turnIndex
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case turnIndex = "turn_index"
        case prompt
    }
}

/// Persisted transcript bundle for a single session.
///
/// Stored at `{root}/{session_id}.transcript.json` alongside the
/// session JSON. Carries its own `session_id` so corrupted or
/// mismatched filename / payload combinations can be detected.
public struct TranscriptRecord: Equatable, Sendable, Codable {
    public var sessionId: SessionId
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var entries: [TranscriptEntry]

    public init(
        sessionId: SessionId,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        entries: [TranscriptEntry] = []
    ) {
        self.sessionId = sessionId
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case sessionId   = "session_id"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case entries
    }
}
