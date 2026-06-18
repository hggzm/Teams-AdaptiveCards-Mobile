// SwiftHarnessCommands — CommandRegistry
//
// Deterministic registry of available commands. `seeded()` returns the
// three upstream-canonical entries (review, agents, setup) in
// declaration order, with the upstream-verbatim descriptions. The
// `execute(name:prompt:)` entry point matches command names
// case-insensitively, returns a `CommandResult` whose `name` is the
// canonical (registered) name on hit and the requested name on miss,
// and produces a deterministic `message` suitable for inference-free
// smoke testing.

import Foundation
import SwiftHarnessCore

/// Deterministic registry of command definitions.
public struct CommandRegistry: Equatable, Sendable {
    /// The registered commands, in declaration / insertion order.
    public let commands: [CommandDefinition]

    /// An empty registry.
    public init() {
        self.commands = []
    }

    /// Build a registry from an explicit list of definitions.
    public init(commands: [CommandDefinition]) {
        self.commands = commands
    }

    /// Canonical seeded registry. The three entries are in the order
    /// review, agents, setup, matching upstream
    /// `CommandRegistry::seeded`.
    public static func seeded() -> CommandRegistry {
        CommandRegistry(commands: [
            CommandDefinition(
                name: CommandName("review"),
                description: "Review code or diffs"
            ),
            CommandDefinition(
                name: CommandName("agents"),
                description: "Inspect agent state"
            ),
            CommandDefinition(
                name: CommandName("setup"),
                description: "Show runtime setup state"
            ),
        ])
    }

    /// Look up a registered command by name, case-insensitively.
    /// Returns the canonical `CommandDefinition` if found, otherwise
    /// `nil`.
    public func find(_ name: CommandName) -> CommandDefinition? {
        let target = name.value.lowercased()
        return self.commands.first { $0.name.value.lowercased() == target }
    }

    /// All registered definitions, in declaration order.
    public func list() -> [CommandDefinition] {
        self.commands
    }

    /// Execute a registered command by name. The match is
    /// case-insensitive; on hit, the result's `name` is the canonical
    /// (registered) name. On miss, the result's `name` is the
    /// requested name and `handled` is `false`.
    ///
    /// The message text intentionally mirrors the upstream Rust shape
    /// so callers (and golden-output tests) can rely on a stable
    /// deterministic string.
    public func execute(_ name: CommandName, prompt: String) -> CommandResult {
        if let match = self.find(name) {
            return CommandResult(
                name: match.name,
                handled: true,
                message: "command '\(match.name)' would handle prompt \"\(prompt)\""
            )
        }
        return CommandResult(
            name: name,
            handled: false,
            message: "unknown command: \(name)"
        )
    }
}
