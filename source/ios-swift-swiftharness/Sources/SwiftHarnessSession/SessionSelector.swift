// SwiftHarnessSession — SessionSelector
//
// Three-armed enum that mirrors the upstream Rust `SessionSelector`:
//   - `.latest`            ← user typed `latest`
//   - `.label(String)`     ← user typed `label:<name>`
//   - `.id(String)`        ← anything else, treated as a raw session id
//
// The parser is strict: a `label:` selector with an empty / whitespace
// payload throws `malformedSelector`; the `latest` keyword is matched
// case-sensitively (matching the upstream constant string).

import Foundation
import SwiftHarnessCore

/// User-supplied selector for a session.
public enum SessionSelector: Equatable, Sendable {
    /// The most recently updated session.
    case latest

    /// A session selected by its (trimmed, non-empty) label.
    case label(String)

    /// A session selected by raw UUID string.
    case id(String)

    /// Wire constant for the `latest` selector keyword.
    public static let latestKeyword: String = "latest"

    /// Wire prefix for label selectors (`label:<name>`).
    public static let labelPrefix: String = "label:"

    /// Parse a raw selector string. The rules:
    ///
    /// - Exactly `"latest"` → `.latest`.
    /// - Starts with `"label:"` → `.label(trimmedRest)`, but throws
    ///   `malformedSelector` if the trimmed rest is empty.
    /// - Anything else → `.id(raw)`. (Validation of the id format is
    ///   the store's responsibility.)
    public static func parse(_ raw: String) throws -> SessionSelector {
        if raw == SessionSelector.latestKeyword {
            return .latest
        }
        if raw.hasPrefix(SessionSelector.labelPrefix) {
            let payload = String(raw.dropFirst(SessionSelector.labelPrefix.count))
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw HarnessError.malformedSelector(raw)
            }
            return .label(trimmed)
        }
        return .id(raw)
    }
}
