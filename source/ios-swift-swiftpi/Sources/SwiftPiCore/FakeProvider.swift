// FakeProvider — deterministic, tape-driven Provider used by tests
// and by tools that need to drive the Agent loop offline.
//
// A "tape" is an array of turns. Each turn is an array of
// `StreamEvent` values that will be replayed in order. The provider
// advances one turn per `stream(...)` call; running out of turns
// produces an empty stream (the agent treats this as "no more
// turns" and terminates).
//
// This is a class-bound actor so multiple agents can share a tape if
// desired; each `stream(...)` call mutates the cursor under the actor
// boundary.

import Foundation

public actor FakeProvider: Provider {
    public let name: String = "fake"
    private var tape: [[StreamEvent]]
    private var cursor: Int = 0

    /// Construct a fake provider with the given turns.
    public init(turns: [[StreamEvent]]) {
        self.tape = turns
    }

    /// How many turns remain unconsumed.
    public var remainingTurns: Int {
        max(0, tape.count - cursor)
    }

    public nonisolated func stream(
        context: Context,
        options: StreamOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                let events = await self.advance()
                for event in events {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Internal: pull the next turn off the tape.
    private func advance() -> [StreamEvent] {
        guard cursor < tape.count else { return [] }
        let events = tape[cursor]
        cursor += 1
        return events
    }
}

// MARK: - Builder

/// Convenience builder for a turn of `StreamEvent`s that mimics what
/// Anthropic's wire produces for a textual or tool-using response.
/// Tests use this to keep tape construction readable.
public enum FakeProviderTape {
    /// Build a single-turn tape that emits a `message_start`, one
    /// text content block carrying `text`, and a `message_stop`.
    public static func textTurn(_ text: String, messageID: String = "msg_test") -> [StreamEvent] {
        var events: [StreamEvent] = []
        events.append(.messageStart(
            MessageStartPayload(message: .object([
                "id": .string(messageID),
                "role": .string("assistant"),
            ]))
        ))
        events.append(.contentBlockStart(
            ContentBlockStartPayload(index: 0, contentBlock: .object([
                "type": .string("text"),
                "text": .string(""),
            ]))
        ))
        events.append(.contentBlockDelta(
            ContentBlockDeltaPayload(index: 0, delta: .object([
                "type": .string("text_delta"),
                "text": .string(text),
            ]))
        ))
        events.append(.contentBlockStop(ContentBlockStopPayload(index: 0)))
        events.append(.messageDelta(
            MessageDeltaPayload(delta: .object([
                "stop_reason": .string("end_turn"),
            ]))
        ))
        events.append(.messageStop)
        return events
    }

    /// Build a single-turn tape that emits a `tool_use` content block
    /// requesting `toolName` with `input`. The agent should respond
    /// by dispatching the tool and starting a follow-up turn.
    public static func toolUseTurn(
        id: String,
        toolName: String,
        input: JSONValue,
        messageID: String = "msg_test_tool"
    ) -> [StreamEvent] {
        var events: [StreamEvent] = []
        events.append(.messageStart(
            MessageStartPayload(message: .object([
                "id": .string(messageID),
                "role": .string("assistant"),
            ]))
        ))
        events.append(.contentBlockStart(
            ContentBlockStartPayload(index: 0, contentBlock: .object([
                "type": .string("tool_use"),
                "id": .string(id),
                "name": .string(toolName),
                "input": input,
            ]))
        ))
        events.append(.contentBlockStop(ContentBlockStopPayload(index: 0)))
        events.append(.messageDelta(
            MessageDeltaPayload(delta: .object([
                "stop_reason": .string("tool_use"),
            ]))
        ))
        events.append(.messageStop)
        return events
    }
}
