// SwiftHarnessCore — Names
//
// Newtype wrappers around `String` for the three name kinds the
// harness manipulates: a `Prompt` (the user-provided text that drives
// the conversation loop), a `ToolName` (the symbolic name of a
// registered tool, e.g. "ReadFile"), and a `CommandName` (the
// symbolic name of a registered command, e.g. "review").
//
// All three encode to / decode from a bare JSON string via a
// single-value container, matching the upstream Rust wire format.

import Foundation

// MARK: - Prompt

/// A user-supplied prompt that drives one turn of the harness loop.
public struct Prompt: Hashable, Sendable, CustomStringConvertible {
    /// Underlying string value.
    public let value: String

    /// Build a `Prompt` from any string-convertible value.
    public init(_ value: String = "") {
        self.value = value
    }

    /// Read-only string view of the prompt text, matching the
    /// upstream Rust `Prompt::as_str` accessor.
    public var asString: String {
        self.value
    }

    public var description: String {
        self.value
    }
}

extension Prompt: Codable {
    public init(from decoder: Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}

// MARK: - ToolName

/// The symbolic name of a registered tool.
public struct ToolName: Hashable, Sendable, CustomStringConvertible {
    /// Underlying string value.
    public let value: String

    /// Build a `ToolName` from any string-convertible value.
    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        self.value
    }
}

extension ToolName: Codable {
    public init(from decoder: Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}

// MARK: - CommandName

/// The symbolic name of a registered command.
public struct CommandName: Hashable, Sendable, CustomStringConvertible {
    /// Underlying string value.
    public let value: String

    /// Build a `CommandName` from any string-convertible value.
    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        self.value
    }
}

extension CommandName: Codable {
    public init(from decoder: Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}
