// Tool — the protocol every built-in (and, eventually, every extension)
// tool implements.
//
// Design intent:
//   - `Sendable` so the agent loop can call a `Tool` from any actor.
//   - Async `execute(input:)` so I/O-bound tools (file reads, network
//     calls in later phases) don't block the agent.
//   - `inputSchema` is opaque JSON (carried as `SwiftPiCore.JSONValue`)
//     because it's primarily a wire object handed to the LLM. The
//     concrete validation lives in each tool's implementation.

import Foundation
import SwiftPiCore

public protocol Tool: Sendable {
    /// The name the LLM uses to refer to the tool, e.g. `"read"`.
    /// Must be globally unique within a `ToolRegistry`.
    var name: String { get }

    /// Human-readable description shown to the LLM.
    var description: String { get }

    /// JSON Schema describing the tool's input object. Carried opaquely
    /// here; the tool itself is responsible for argument validation in
    /// `execute(input:)`.
    var inputSchema: JSONValue { get }

    /// Run the tool. Failures bubble out as `Error`; the caller
    /// (typically the agent loop) maps them to `tool_result` blocks
    /// with `is_error: true`.
    func execute(input: JSONValue) async throws -> ToolOutput
}

extension Tool {
    /// Convenience for callers that already constructed a `ToolDef`
    /// somewhere else: produce the same shape from this tool's
    /// metadata.
    public var toolDef: ToolDef {
        ToolDef(name: name, description: description, inputSchema: inputSchema)
    }
}
