// SwiftHarnessTools — PermissionPolicy
//
// The permission policy is a list of denied prefixes. When asked
// whether a `ToolName` is allowed, the policy lowercases the tool
// name and the prefixes, then checks for any `starts_with` match.
// On match it returns a `PermissionDenial` whose `subject` is the
// original (case-preserving) tool name and whose `reason` is the
// upstream-verbatim string `"tool blocked by permission policy"`.
//
// The policy is intentionally NOT Codable: it is a runtime-only
// configuration value, not part of the persisted session bundle.

import Foundation
import SwiftHarnessCore

/// Prefix-based deny policy applied to tool invocations.
public struct PermissionPolicy: Equatable, Sendable {
    /// The list of denied prefixes, in original insertion order.
    /// Prefix matching is performed case-insensitively, but the
    /// stored form preserves the caller's case so introspection
    /// (`deniedPrefixes`) round-trips exactly what was supplied.
    public let deniedPrefixes: [String]

    /// An empty policy that denies nothing.
    public init() {
        self.deniedPrefixes = []
    }

    /// Build a policy from a sequence of prefixes.
    public init<S: Sequence>(deniedPrefixes prefixes: S)
        where S.Element == String
    {
        self.deniedPrefixes = Array(prefixes)
    }

    /// Convenience initializer matching the upstream
    /// `PermissionPolicy::with_denied_prefixes` shape.
    public static func withDeniedPrefixes<S: Sequence>(_ prefixes: S) -> PermissionPolicy
        where S.Element == String
    {
        PermissionPolicy(deniedPrefixes: prefixes)
    }

    /// Variadic-friendly factory.
    public static func withDeniedPrefixes(_ prefixes: String...) -> PermissionPolicy {
        PermissionPolicy(deniedPrefixes: prefixes)
    }

    /// Return a structured denial if `toolName` matches any denied
    /// prefix (case-insensitively), or `nil` otherwise.
    public func denial(for toolName: ToolName) -> PermissionDenial? {
        let lowered = toolName.value.lowercased()
        let isDenied = self.deniedPrefixes.contains { prefix in
            lowered.hasPrefix(prefix.lowercased())
        }
        guard isDenied else { return nil }
        return PermissionDenial(
            subject: toolName.value,
            reason: "tool blocked by permission policy"
        )
    }
}
