// SwiftHarnessCommands — CommandResult
//
// Result returned by `CommandRegistry.execute(name:prompt:)`. `handled`
// is `true` when a command matched the requested name (case-insensitive)
// and `false` when no registered command matched. `name` is the
// canonical (registered) name on hit and the requested name on miss.
// `message` is deterministic and suitable for transcript echo and for
// inference-free smoke testing.
//
// JSON wire shape: `{"handled": ..., "message": "...", "name": "..."}`
// once keys are sorted.

import Foundation
import SwiftHarnessCore

/// Result of a single `CommandRegistry.execute` call.
public struct CommandResult: Hashable, Sendable, Codable {
    /// The matched command name (canonical) on hit; the requested
    /// name on miss.
    public let name: CommandName

    /// `true` when a registered command matched the requested name.
    public let handled: Bool

    /// Human-readable summary of the invocation outcome.
    public let message: String

    /// Build a `CommandResult`.
    public init(name: CommandName, handled: Bool, message: String) {
        self.name = name
        self.handled = handled
        self.message = message
    }
}
