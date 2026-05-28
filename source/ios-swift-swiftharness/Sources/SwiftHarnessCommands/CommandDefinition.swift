// SwiftHarnessCommands — CommandDefinition
//
// Static record for one registered command. Mirrors `ToolDefinition`
// from SwiftHarnessTools shape-for-shape, but namespaced on
// `CommandName` instead of `ToolName`.
//
// JSON wire shape: `{"description": "...", "name": "..."}` once keys
// are sorted, matching the serde-derived upstream form.

import Foundation
import SwiftHarnessCore

/// Static record for one registered command.
public struct CommandDefinition: Hashable, Sendable, Codable {
    /// Symbolic command name (e.g. `CommandName("review")`).
    public let name: CommandName

    /// Short human-readable description of what the command does.
    public let description: String

    /// Build a `CommandDefinition`.
    public init(name: CommandName, description: String) {
        self.name = name
        self.description = description
    }
}
