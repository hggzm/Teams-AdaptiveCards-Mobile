// AgentEvent — structured events the Agent emits over its lifetime.
//
// Stable ordering invariants the agent loop guarantees:
//
//   agentStart
//   ( turnStart  →  (textDelta | toolUseRequested | toolResultProduced)*
//                →  turnEnd )+
//   agentEnd
//
// `turnEnd` carries the model's stop reason ("end_turn", "tool_use",
// "max_tokens", "stop_sequence"); a `tool_use` stop launches a new
// turn after dispatching the tool, otherwise the agent terminates.
// Tool recursion is bounded by `Agent.maxToolIterations` (default 50,
// matching upstream).

import Foundation

public enum AgentEvent: Sendable, Equatable {
    /// Emitted exactly once at the beginning of `Agent.run`.
    case agentStart(sessionID: String?)

    /// Emitted at the start of each model turn.
    case turnStart(turnIndex: Int)

    /// Incremental assistant text. Carried verbatim from the
    /// provider's `content_block_delta` events.
    case textDelta(turnIndex: Int, index: Int, text: String)

    /// A tool call was requested by the assistant. The agent will
    /// dispatch the tool, capture the result, and feed it back in a
    /// follow-up turn.
    case toolUseRequested(turnIndex: Int, id: String, name: String, input: JSONValue)

    /// A tool result was produced. `output` is the agent's
    /// rendering; `isError` reflects whether the dispatcher reported
    /// failure.
    case toolResultProduced(
        turnIndex: Int,
        id: String,
        name: String,
        output: String,
        isError: Bool
    )

    /// Emitted at the end of each model turn.
    case turnEnd(turnIndex: Int, stopReason: String?)

    /// Emitted exactly once at the end of `Agent.run`, regardless of
    /// whether the run terminated normally or via error.
    case agentEnd(stopReason: String?)
}
