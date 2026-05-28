// SessionEntry — one row of a JSONL v3 session file.
//
// Each line of a `.pi/sessions/*.jsonl` file decodes into a single
// `SessionEntry`. The variants and their wire shape are byte-compatible
// with the upstream TypeScript pi coding agent (earendil-works/pi,
// package @earendil-works/pi-coding-agent) so a user can cross-read
// sessions between implementations as a convenience — though that
// compatibility is not a guarantee, only a current property.
//
// Discriminator: the JSON `type` field. swiftpi uses a Swift enum here
// (rather than struct-with-optional-fields) so the compiler catches
// missing-case bugs at compile time.

import Foundation
import SwiftPiCore

public enum SessionEntry: Sendable, Equatable {
    /// `session` — the header row written exactly once at the top of
    /// every session file. Always v3 in this implementation.
    case session(SessionHeader)

    /// `message` — a conversation turn. Carries the speaker, the
    /// content blocks, a parent reference for tree branching, and an
    /// optional timestamp.
    case message(Message)

    /// `model_change` — records that the active model changed mid-session.
    /// `parent` points at the message preceding the change.
    case modelChange(id: String, parent: String?, model: String)

    /// `compaction` — placeholder for the compaction-summary row used by
    /// the agent loop. The real compaction algorithm ships in Phase 6;
    /// this case exists so v3 files containing compaction rows round-trip
    /// cleanly today.
    case compaction(CompactionEntry)
}

// MARK: - Per-variant payloads

public struct SessionHeader: Codable, Sendable, Equatable {
    /// JSONL session format version. swiftpi only writes `3`; reading
    /// older versions surfaces a typed `SwiftPiError.malformedJSON`.
    public let version: Int

    /// Working directory at session start. Stored verbatim from the
    /// host so that resume tooling can match `cwd`.
    public let cwd: String?

    /// Session creation timestamp.
    public let created: Date?

    public init(version: Int = 3, cwd: String? = nil, created: Date? = nil) {
        self.version = version
        self.cwd = cwd
        self.created = created
    }
}

public struct CompactionEntry: Codable, Sendable, Equatable {
    public let id: String
    public let parent: String?
    /// The compaction summary text (assistant-authored). Optional in
    /// Phase 3 because the real compactor in Phase 6 might emit
    /// structured content blocks instead of a single string.
    public let summary: String?
    /// The id of the first kept message (rows before this id are
    /// considered "rolled into the summary").
    public let firstKeptId: String?

    public init(
        id: String,
        parent: String? = nil,
        summary: String? = nil,
        firstKeptId: String? = nil
    ) {
        self.id = id
        self.parent = parent
        self.summary = summary
        self.firstKeptId = firstKeptId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case parent
        case summary
        case firstKeptId = "first_kept_id"
    }
}

// MARK: - Codable

extension SessionEntry: Codable {
    private enum DiscriminatorKey: String, CodingKey {
        case type
    }

    private enum Discriminator: String {
        case session
        case message
        case modelChange = "model_change"
        case compaction
    }

    private enum ModelChangeKeys: String, CodingKey {
        case id
        case parent
        case model
    }

    public init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: DiscriminatorKey.self)
        let rawType = try typeContainer.decode(String.self, forKey: .type)
        guard let kind = Discriminator(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: typeContainer,
                debugDescription: "Unknown session entry type: \(rawType)"
            )
        }
        switch kind {
        case .session:
            self = .session(try SessionHeader(from: decoder))
        case .message:
            self = .message(try Message(from: decoder))
        case .modelChange:
            let c = try decoder.container(keyedBy: ModelChangeKeys.self)
            self = .modelChange(
                id: try c.decode(String.self, forKey: .id),
                parent: try c.decodeIfPresent(String.self, forKey: .parent),
                model: try c.decode(String.self, forKey: .model)
            )
        case .compaction:
            self = .compaction(try CompactionEntry(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .session(let header):
            try header.encode(to: encoder)
            var c = encoder.container(keyedBy: DiscriminatorKey.self)
            try c.encode(Discriminator.session.rawValue, forKey: .type)
        case .message(let message):
            try message.encode(to: encoder)
            var c = encoder.container(keyedBy: DiscriminatorKey.self)
            try c.encode(Discriminator.message.rawValue, forKey: .type)
        case .modelChange(let id, let parent, let model):
            var c = encoder.container(keyedBy: DiscriminatorKey.self)
            try c.encode(Discriminator.modelChange.rawValue, forKey: .type)
            var mc = encoder.container(keyedBy: ModelChangeKeys.self)
            try mc.encode(id, forKey: .id)
            try mc.encodeIfPresent(parent, forKey: .parent)
            try mc.encode(model, forKey: .model)
        case .compaction(let entry):
            try entry.encode(to: encoder)
            var c = encoder.container(keyedBy: DiscriminatorKey.self)
            try c.encode(Discriminator.compaction.rawValue, forKey: .type)
        }
    }
}

// MARK: - Convenience accessors

extension SessionEntry {
    /// Per-row id, when the row carries one. `session` headers do not.
    public var id: String? {
        switch self {
        case .session: return nil
        case .message(let m): return m.id
        case .modelChange(let id, _, _): return id
        case .compaction(let c): return c.id
        }
    }

    /// Per-row parent id, when the row carries one. `session` headers do
    /// not; the first real entry of a session has `nil` for parent.
    public var parent: String? {
        switch self {
        case .session: return nil
        case .message(let m): return m.parent
        case .modelChange(_, let parent, _): return parent
        case .compaction(let c): return c.parent
        }
    }

    /// `true` only for the `session` header row.
    public var isHeader: Bool {
        if case .session = self { return true }
        return false
    }
}
