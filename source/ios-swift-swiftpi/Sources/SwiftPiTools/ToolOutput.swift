// ToolOutput — the structured result of running a tool.
//
// Wire shape mirrors upstream so a `tool_result` content block can be
// assembled from a `ToolOutput` without further translation:
//
//   - `content` is the textual result the LLM sees.
//   - `metadata` carries structured fields (truncated flags, line
//     counts, edit diffs) the agent or UI may want.
//   - `isError` exists for tools that want to signal a recoverable
//     failure without `throw`ing — most tools throw instead, and the
//     agent layer flips this flag at the `tool_result` boundary.

import Foundation
import SwiftPiCore

public struct ToolOutput: Sendable, Equatable {
    public var content: String
    public var metadata: [String: JSONValue]
    public var isError: Bool

    public init(
        content: String,
        metadata: [String: JSONValue] = [:],
        isError: Bool = false
    ) {
        self.content = content
        self.metadata = metadata
        self.isError = isError
    }
}
