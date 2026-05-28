// ToolRegistry — looks up a `Tool` by name and dispatches.
//
// The registry is intentionally a plain `struct` rather than an actor:
// it is built once at startup, frozen, and consulted from many places.
// Each `Tool` is itself `Sendable`, so concurrent `execute(_:input:)`
// calls are safe to issue from multiple tasks.

import Foundation
import SwiftPiCore

public struct ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    /// Build a registry from a list of tools. Tool name collisions
    /// throw at construction time — the agent never sees an ambiguous
    /// registry.
    public init(tools: [any Tool]) throws {
        var indexed: [String: any Tool] = [:]
        for tool in tools {
            if indexed[tool.name] != nil {
                throw SwiftPiError.io("ToolRegistry: duplicate tool name `\(tool.name)`")
            }
            indexed[tool.name] = tool
        }
        self.tools = indexed
    }

    /// Default registry with the five built-in tools: `read`, `write`,
    /// `edit`, `ls`, and `bash`.
    public static func defaultBuiltins() -> ToolRegistry {
        // `try!` is safe here: the five built-in names are unique by
        // construction, so the collision branch is unreachable.
        do {
            return try ToolRegistry(tools: [
                ReadFileTool(),
                WriteFileTool(),
                EditFileTool(),
                ListDirectoryTool(),
                BashTool(),
            ])
        } catch {
            fatalError("ToolRegistry.defaultBuiltins: unreachable — built-ins must be unique (\(error))")
        }
    }

    /// All tools currently registered, in alphabetical order. Useful
    /// for emitting the `tools` array of a `Context`.
    public var allTools: [any Tool] {
        tools.keys.sorted().compactMap { tools[$0] }
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// Execute the named tool with the given input. Throws
    /// `SwiftPiError.io` with a descriptive message for unknown
    /// names; otherwise propagates the tool's own errors.
    public func execute(_ name: String, input: JSONValue) async throws -> ToolOutput {
        guard let tool = tools[name] else {
            throw SwiftPiError.io("ToolRegistry: unknown tool `\(name)`")
        }
        return try await tool.execute(input: input)
    }

    /// Produce a `ToolDef` for every registered tool, in alphabetical
    /// order — the conventional shape for an agent's `Context.tools`.
    public var toolDefs: [ToolDef] {
        allTools.map { $0.toolDef }
    }
}
