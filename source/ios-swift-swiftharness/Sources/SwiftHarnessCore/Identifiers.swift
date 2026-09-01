// SwiftHarnessCore — Identifiers
//
// Newtype wrappers around primitive scalars used to identify sessions
// and structural positions inside a transcript. Each wraps a single
// scalar and encodes to / decodes from the bare scalar (single-value
// JSON container), giving wire-compatibility with the upstream Rust
// harness JSON format.

import Foundation

// MARK: - SessionId

/// Opaque identifier for a single session, backed by a UUID.
///
/// `SessionId()` generates a fresh random (v4) UUID. The JSON
/// representation is the canonical lowercase UUID string, matching
/// the upstream Rust `Uuid` `Display` impl.
public struct SessionId: Hashable, Sendable, CustomStringConvertible {
    /// Underlying UUID value.
    public let uuid: UUID

    /// Generate a fresh random `SessionId`.
    public init() {
        self.uuid = UUID()
    }

    /// Build a `SessionId` from a pre-existing UUID (useful for tests
    /// and for re-hydrating from persisted state).
    public init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Parse a `SessionId` from the canonical UUID string form.
    /// Returns `nil` for malformed input.
    public init?(string: String) {
        guard let parsed = UUID(uuidString: string) else { return nil }
        self.uuid = parsed
    }

    /// Canonical lowercase UUID string.
    public var description: String {
        // Foundation's `UUID.uuidString` is uppercase; the upstream
        // Rust `Uuid::Display` is lowercase. Match the upstream so
        // persisted bundles stay byte-identical across implementations.
        uuid.uuidString.lowercased()
    }
}

extension SessionId: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid uuid: \(raw)"
            )
        }
        self.uuid = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }
}

// MARK: - TurnIndex

/// Zero-based position of a turn inside a transcript.
///
/// Wraps a Swift `Int`; encoded as a bare JSON integer. The default
/// value is `0`, matching the upstream Rust `TurnIndex(usize)` newtype
/// with `#[derive(Default)]`.
public struct TurnIndex: Hashable, Sendable, Comparable {
    /// Underlying integer value.
    public let value: Int

    /// Build a `TurnIndex` from a raw integer.
    public init(_ value: Int = 0) {
        self.value = value
    }

    public static func < (lhs: TurnIndex, rhs: TurnIndex) -> Bool {
        lhs.value < rhs.value
    }
}

extension TurnIndex: Codable {
    public init(from decoder: Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}

// MARK: - MatchScore

/// Score returned by the deterministic router when matching a prompt
/// against a registered command or tool. Higher means a closer match.
///
/// Wraps a Swift `Int`; encoded as a bare JSON integer. The default
/// value is `0`.
public struct MatchScore: Hashable, Sendable, Comparable {
    /// Underlying integer value.
    public let value: Int

    /// Build a `MatchScore` from a raw integer.
    public init(_ value: Int = 0) {
        self.value = value
    }

    public static func < (lhs: MatchScore, rhs: MatchScore) -> Bool {
        lhs.value < rhs.value
    }
}

extension MatchScore: Codable {
    public init(from decoder: Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}
