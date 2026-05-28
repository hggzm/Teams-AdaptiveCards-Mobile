
import Foundation
import Testing
@testable import SwiftPiCore

@Suite("FakeProvider")
struct FakeProviderTests {
    @Test("returns the events of the first turn, then nothing")
    func consumesTapeInOrder() async throws {
        let provider = FakeProvider(turns: [
            FakeProviderTape.textTurn("hello"),
        ])
        var collected: [StreamEvent] = []
        for try await event in provider.stream(
            context: Context(),
            options: StreamOptions(model: "x", maxTokens: 1)
        ) {
            collected.append(event)
        }
        #expect(collected.contains(.messageStop))
        let remaining = await provider.remainingTurns
        #expect(remaining == 0)
    }

    @Test("multi-turn tape advances per stream() call")
    func advancesAcrossTurns() async throws {
        let provider = FakeProvider(turns: [
            FakeProviderTape.textTurn("first"),
            FakeProviderTape.textTurn("second"),
        ])
        // First call drains turn 1.
        for try await _ in provider.stream(
            context: Context(),
            options: StreamOptions(model: "x", maxTokens: 1)
        ) {}
        // Second call should drain turn 2.
        var collected: [StreamEvent] = []
        for try await event in provider.stream(
            context: Context(),
            options: StreamOptions(model: "x", maxTokens: 1)
        ) {
            collected.append(event)
        }
        // The text_delta inside the second turn should mention "second".
        let hasSecond = collected.contains { event in
            if case .contentBlockDelta(let p) = event {
                return p.delta.objectValue?["text"]?.stringValue == "second"
            }
            return false
        }
        #expect(hasSecond)
    }

    @Test("exhausted tape yields an empty stream")
    func emptyAfterExhaustion() async throws {
        let provider = FakeProvider(turns: [])
        var count = 0
        for try await _ in provider.stream(
            context: Context(),
            options: StreamOptions(model: "x", maxTokens: 1)
        ) {
            count += 1
        }
        #expect(count == 0)
    }
}

@Suite("Agent — single-turn text response")
struct AgentSingleTurnTests {
    @Test("agent emits agentStart, turnStart, textDelta, turnEnd, agentEnd in order")
    func canonicalEventOrder() async throws {
        let provider = FakeProvider(turns: [
            FakeProviderTape.textTurn("hello world"),
        ])
        let agent = Agent(
            provider: provider,
            dispatcher: { _, _ in ("unused", false) },
            sessionID: "test-session"
        )
        var events: [AgentEvent] = []
        for try await event in agent.run(
            initialContext: Context(
                system: nil,
                messages: [Message(id: "user-1", role: .user, content: [.text("hi")])],
                tools: []
            ),
            options: StreamOptions(model: "claude-x", maxTokens: 256)
        ) {
            events.append(event)
        }
        // First and last events are the lifecycle bookends.
        #expect(events.first == .agentStart(sessionID: "test-session"))
        if case .agentEnd(let reason) = events.last {
            #expect(reason == "end_turn")
        } else {
            Issue.record("Expected final agentEnd, got \(String(describing: events.last))")
        }
        // Exactly one turnStart and one turnEnd for the single turn.
        let turnStarts = events.filter { if case .turnStart = $0 { return true } else { return false } }
        let turnEnds = events.filter { if case .turnEnd = $0 { return true } else { return false } }
        #expect(turnStarts.count == 1)
        #expect(turnEnds.count == 1)
        // Text delta carries the whole tape text.
        let combined = events.compactMap { event -> String? in
            if case .textDelta(_, _, let text) = event { return text }
            return nil
        }.joined()
        #expect(combined == "hello world")
    }
}

@Suite("Agent — tool dispatch")
struct AgentToolDispatchTests {
    @Test("two-turn tool_use followed by text completes with both tool events and final text")
    func toolUseThenText() async throws {
        let provider = FakeProvider(turns: [
            FakeProviderTape.toolUseTurn(
                id: "toolu_1",
                toolName: "echo",
                input: .object(["text": .string("hi tool")])
            ),
            FakeProviderTape.textTurn("done"),
        ])

        // The dispatcher echoes back the input's `text` field.
        let agent = Agent(
            provider: provider,
            dispatcher: { name, input in
                #expect(name == "echo")
                let text = input.objectValue?["text"]?.stringValue ?? ""
                return ("ECHOED: \(text)", false)
            }
        )

        var events: [AgentEvent] = []
        for try await event in agent.run(
            initialContext: Context(
                messages: [Message(id: "u1", role: .user, content: [.text("call echo")])]
            ),
            options: StreamOptions(model: "claude-x", maxTokens: 256)
        ) {
            events.append(event)
        }

        // Expect toolUseRequested + toolResultProduced in the first turn.
        let dispatched = events.contains { event in
            if case .toolUseRequested(_, _, let name, _) = event { return name == "echo" }
            return false
        }
        let resulted = events.contains { event in
            if case .toolResultProduced(_, _, _, let text, _) = event {
                return text.contains("ECHOED: hi tool")
            }
            return false
        }
        #expect(dispatched)
        #expect(resulted)
        // Two turns ran.
        let turnEnds = events.compactMap { event -> Int? in
            if case .turnEnd(let index, _) = event { return index }
            return nil
        }
        #expect(turnEnds == [0, 1])
        // Final agentEnd reflects the second turn's end_turn.
        if case .agentEnd(let reason) = events.last {
            #expect(reason == "end_turn")
        } else {
            Issue.record("Expected agentEnd at the tail of the run")
        }
    }

    @Test("capability-denied tool surfaces as isError result, agent continues")
    func capabilityDeniedFailsClosed() async throws {
        let provider = FakeProvider(turns: [
            FakeProviderTape.toolUseTurn(
                id: "toolu_x",
                toolName: "dangerous",
                input: .object([:])
            ),
            FakeProviderTape.textTurn("recovered"),
        ])
        let agent = Agent(
            provider: provider,
            dispatcher: { _, _ in
                Issue.record("Dispatcher should not be called for denied tool")
                return ("should not run", false)
            },
            capabilities: { name in name != "dangerous" }
        )
        var sawDenial = false
        var sawRecoveryText = false
        for try await event in agent.run(
            initialContext: Context(),
            options: StreamOptions(model: "x", maxTokens: 10)
        ) {
            if case .toolResultProduced(_, _, _, let text, let isError) = event,
               isError,
               text.contains("capability denied")
            {
                sawDenial = true
            }
            if case .textDelta(_, _, let text) = event, text.contains("recovered") {
                sawRecoveryText = true
            }
        }
        #expect(sawDenial)
        #expect(sawRecoveryText)
    }

    @Test("max iteration cap throws iterationLimitExceeded after the cap is hit")
    func iterationLimitFires() async {
        // Build a tape that returns tool_use forever — well past the
        // small cap below. The agent must abort with the typed error.
        var tape: [[StreamEvent]] = []
        for i in 0..<10 {
            tape.append(FakeProviderTape.toolUseTurn(
                id: "toolu_\(i)",
                toolName: "loop",
                input: .object([:])
            ))
        }
        let provider = FakeProvider(turns: tape)
        let agent = Agent(
            provider: provider,
            dispatcher: { _, _ in ("ok", false) },
            maxToolIterations: 3
        )
        var threwIterationLimit = false
        do {
            for try await _ in agent.run(
                initialContext: Context(),
                options: StreamOptions(model: "x", maxTokens: 10)
            ) {
                // drain
            }
        } catch let error as SwiftPiError {
            if case .iterationLimitExceeded(let limit) = error {
                #expect(limit == 3)
                threwIterationLimit = true
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(threwIterationLimit)
    }
}

@Suite("Agent — provider errors")
struct AgentProviderErrorTests {
    @Test("provider error event terminates the run with providerRejected")
    func providerErrorBubbles() async {
        let provider = FakeProvider(turns: [
            [
                .messageStart(MessageStartPayload(message: .object([:]))),
                .error(StreamErrorPayload(type: "overloaded_error", message: "slow down")),
            ],
        ])
        let agent = Agent(
            provider: provider,
            dispatcher: { _, _ in ("never", false) }
        )
        var threwProviderRejected = false
        do {
            for try await _ in agent.run(
                initialContext: Context(),
                options: StreamOptions(model: "x", maxTokens: 1)
            ) {
                // drain
            }
        } catch let error as SwiftPiError {
            if case .providerRejected = error {
                threwProviderRejected = true
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(threwProviderRejected)
    }
}
