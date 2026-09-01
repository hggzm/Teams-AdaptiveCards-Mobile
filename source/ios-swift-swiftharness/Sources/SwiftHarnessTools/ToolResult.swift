// SwiftHarnessTools — ToolResult
//
// Result returned by `ToolRegistry.execute(name:payload:)`. `handled`
// is `true` when a tool matched the requested name (case-insensitive)
// and `false` when no registered tool matched. `name` is the canonical
// (registered) name on hit and the requested name on miss. `message`
// is a deterministic, human-readable summary suitable for transcript
// echo and for inference-free smoke testing.
//
// JSON wire shape: `{"handled": ..., "message": "...", "name": "..."}`
// once keys are sorted.

import Foundation
import SwiftHarnessCore

/// Result of a single `ToolRegistry.execute` call.
public struct ToolResult: Hashable, Sendable, Codable {
    /// The matched tool name (canonical) on hit; the requested name
    /// on miss.
    public let name: ToolName

    /// `true` when a registered tool matched the requested name.
    public let handled: Bool

    /// Human-readable summary of the invocation outcome.
    public let message: String

    /// Build a `ToolResult`.
    public init(name: ToolName, handled: Bool, message: String) {
        self.name = name
        self.handled = handled
        self.message = message
    }
}
