// SwiftHarnessTools — ToolRegistry
//
// Deterministic registry of available tools. `seeded()` returns the
// three upstream-canonical entries (ReadFile, EditFile, Bash) in
// declaration order, with the upstream-verbatim descriptions. The
// `execute(name:payload:)` entry point matches tool names
// case-insensitively, returns a `ToolResult` whose `name` is the
// canonical (registered) name on hit and the requested name on miss,
// and produces a deterministic `message` suitable for inference-free
// smoke testing.
//
// NOTE: At this phase the registry does NOT perform real I/O — the
// "would handle payload …" message is intentional and matches the
// upstream behavior. Real I/O lands in a later phase as additional
// concrete tool implementations layered on top of `ToolDefinition`.

import Foundation
import SwiftHarnessCore

/// Deterministic registry of tool definitions.
public struct ToolRegistry: Equatable, Sendable {
    /// The registered tools, in declaration / insertion order.
    public let tools: [ToolDefinition]

    /// An empty registry.
    public init() {
        self.tools = []
    }

    /// Build a registry from an explicit list of definitions.
    public init(tools: [ToolDefinition]) {
        self.tools = tools
    }

    /// Canonical seeded registry. The three entries are in the order
    /// ReadFile, EditFile, Bash, matching upstream `ToolRegistry::seeded`.
    public static func seeded() -> ToolRegistry {
        ToolRegistry(tools: [
            ToolDefinition(
                name: ToolName("ReadFile"),
                description: "Read a file from disk"
            ),
            ToolDefinition(
                name: ToolName("EditFile"),
                description: "Edit a file on disk"
            ),
            ToolDefinition(
                name: ToolName("Bash"),
                description: "Execute shell commands"
            ),
        ])
    }

    /// Look up a registered tool by name, case-insensitively. Returns
    /// the canonical `ToolDefinition` if found, otherwise `nil`.
    public func find(_ name: ToolName) -> ToolDefinition? {
        let target = name.value.lowercased()
        return self.tools.first { $0.name.value.lowercased() == target }
    }

    /// All registered definitions, in declaration order.
    public func list() -> [ToolDefinition] {
        self.tools
    }

    /// Execute a registered tool by name. The match is
    /// case-insensitive; on hit, the result's `name` is the canonical
    /// (registered) name. On miss, the result's `name` is the
    /// requested name and `handled` is `false`.
    ///
    /// The message text intentionally mirrors the upstream Rust shape
    /// so callers (and golden-output tests) can rely on a stable
    /// deterministic string.
    public func execute(_ name: ToolName, payload: String) -> ToolResult {
        if let match = self.find(name) {
            return ToolResult(
                name: match.name,
                handled: true,
                message: "tool '\(match.name)' would handle payload \"\(payload)\""
            )
        }
        return ToolResult(
            name: name,
            handled: false,
            message: "unknown tool: \(name)"
        )
    }
}
