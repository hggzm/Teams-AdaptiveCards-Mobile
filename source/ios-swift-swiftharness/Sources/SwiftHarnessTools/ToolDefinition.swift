// SwiftHarnessTools — ToolDefinition
//
// Descriptive record for a registered tool: a symbolic name plus a
// short human-readable description. The runtime never inspects the
// description programmatically; it is surfaced through introspection
// CLI commands (Phase 6) and through transcript records.
//
// JSON wire shape: `{"description": "...", "name": "..."}` once
// keys are sorted, matching the serde-derived upstream form.

import Foundation
import SwiftHarnessCore

/// Static record for one registered tool.
public struct ToolDefinition: Hashable, Sendable, Codable {
    /// Symbolic tool name (e.g. `ToolName("ReadFile")`).
    public let name: ToolName

    /// Short human-readable description of what the tool does.
    public let description: String

    /// Build a `ToolDefinition`.
    public init(name: ToolName, description: String) {
        self.name = name
        self.description = description
    }
}
