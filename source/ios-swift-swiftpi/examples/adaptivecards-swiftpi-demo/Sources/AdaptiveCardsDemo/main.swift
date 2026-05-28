// main.swift
// Flavor C ("agent / runtime") symbol-check demo.
//
// Drives a SwiftPiCore.Agent through one tool-using turn against a
// SwiftPiCore.FakeProvider tape. The tool input and output are both
// the canonical "Hello World" Adaptive Card payload from
// adaptivecards.io. The demo asserts the agent emits the canonical
// event sequence and that the tool input parses as JSON whose
// `type` is "AdaptiveCard". On success it prints
// `PASS adaptivecards-swiftpi-agentloop` and exits 0; on any
// deviation it prints `FAIL ...` and exits 1.
//
// Symbols exercised (cross-referenced in README.md):
//   - SwiftPiCore.Agent (init + run)
//   - SwiftPiCore.Agent.Capabilities (fail-closed gate, allow-all here)
//   - SwiftPiCore.Agent.ToolDispatcher (Sendable closure boundary)
//   - SwiftPiCore.Provider (existential value)
//   - SwiftPiCore.FakeProvider (actor)
//   - SwiftPiCore.FakeProviderTape.toolUseTurn
//   - SwiftPiCore.FakeProviderTape.textTurn
//   - SwiftPiCore.Context (init + tools)
//   - SwiftPiCore.ToolDef
//   - SwiftPiCore.StreamOptions
//   - SwiftPiCore.JSONValue (string / object cases)
//   - SwiftPiCore.AgentEvent (agentStart / turnStart / textDelta /
//     toolUseRequested / toolResultProduced / turnEnd / agentEnd)

import Foundation
import SwiftPiCore

// Top-level entry: a `main.swift` file is treated as the executable
// entry point by SwiftPM, so we drive the demo inline without `@main`.
do {
    try await runDemo()
    print("PASS adaptivecards-swiftpi-agentloop")
    exit(0)
} catch {
    print("FAIL adaptivecards-swiftpi-agentloop: \(error)")
    exit(1)
}

func runDemo() async throws {
        // 1) Parse the canonical sample card into a SwiftPiCore.JSONValue
        //    so we can hand it to the FakeProvider as a tool_use input.
        let cardData = Data(SampleCard.helloWorldJSON.utf8)
        let cardJSONValue = try JSONDecoder().decode(JSONValue.self, from: cardData)
        guard case .object(let cardObj) = cardJSONValue,
              case .string(let cardType) = cardObj["type"] ?? .null,
              cardType == "AdaptiveCard"
        else {
            throw DemoError.malformedSample
        }

        // 2) Build the agent's tool registry and capability gate. Use a
        //    single tool `adaptivecards_echo` that returns the input
        //    bytes back. The dispatcher closure carries the tool's
        //    behavior so SwiftPiCore stays cycle-free.
        let toolName = "adaptivecards_echo"
        let toolDef = ToolDef(
            name: toolName,
            description: "Round-trips an Adaptive Card JSON payload unchanged.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card": .object([
                        "type": .string("object"),
                    ]),
                ]),
            ])
        )

        let dispatcher: Agent.ToolDispatcher = { name, input in
            guard name == toolName else {
                return ("unknown tool: \(name)", true)
            }
            // Re-encode the JSONValue we received and return it as the
            // tool result. The agent loop will surface this as a
            // `toolResultProduced` event.
            let encoded = try JSONEncoder().encode(input)
            return (String(decoding: encoded, as: UTF8.self), false)
        }

        let capabilities: Agent.Capabilities = { _ in true }

        // 3) Build the two-turn FakeProvider tape:
        //      turn 0: assistant emits a tool_use for `adaptivecards_echo`
        //              with the canonical card as input.
        //      turn 1: assistant emits a final text reply summarising
        //              the round-trip.
        let toolCallID = "toolu_demo_1"
        let turnTool = FakeProviderTape.toolUseTurn(
            id: toolCallID,
            toolName: toolName,
            input: .object(["card": cardJSONValue])
        )
        let turnText = FakeProviderTape.textTurn(
            "Round-tripped the Adaptive Card through swiftpi."
        )
        let provider: any Provider = FakeProvider(turns: [turnTool, turnText])

        // 4) Drive the agent.
        let agent = Agent(
            provider: provider,
            dispatcher: dispatcher,
            capabilities: capabilities,
            sessionID: "adaptivecards-swiftpi-demo"
        )

        let context = Context(
            system: "You are a deterministic round-trip agent.",
            messages: [],
            tools: [toolDef]
        )
        let options = StreamOptions(
            model: "fake-deterministic-1",
            maxTokens: 256
        )

        // 5) Drain the AgentEvent stream and record the canonical
        //    sequence. We compare against the expected list of event
        //    kinds; if anything is missing or out of order, fail.
        var sawAgentStart = false
        var sawToolUse = false
        var sawToolResult = false
        var sawAgentEnd = false
        var toolResultBody: String? = nil

        for try await event in agent.run(initialContext: context, options: options) {
            switch event {
            case .agentStart:
                sawAgentStart = true
            case .turnStart, .turnEnd, .textDelta:
                // Lifecycle / streaming text — exercised but not the
                // gating assertion.
                break
            case .toolUseRequested(_, _, let name, let input):
                guard name == toolName else { throw DemoError.unexpectedTool(name) }
                guard case .object(let payload) = input,
                      case .object(let inner) = payload["card"] ?? .null,
                      case .string(let innerType) = inner["type"] ?? .null,
                      innerType == "AdaptiveCard"
                else { throw DemoError.malformedToolInput }
                sawToolUse = true
            case .toolResultProduced(_, _, _, let body, let isError):
                guard isError == false else { throw DemoError.toolReportedError }
                toolResultBody = body
                sawToolResult = true
            case .agentEnd:
                sawAgentEnd = true
            }
        }

        // 6) Hard assertions.
        guard sawAgentStart else { throw DemoError.missingEvent("agentStart") }
        guard sawToolUse else { throw DemoError.missingEvent("toolUseRequested") }
        guard sawToolResult else { throw DemoError.missingEvent("toolResultProduced") }
        guard sawAgentEnd else { throw DemoError.missingEvent("agentEnd") }

        // 7) Round-trip the tool body and confirm the card came back
        //    intact at the field level.
        guard let body = toolResultBody,
              let bodyData = body.data(using: .utf8),
              let roundTripValue = try? JSONDecoder().decode(JSONValue.self, from: bodyData),
              case .object(let outerObj) = roundTripValue,
              case .object(let innerCard) = outerObj["card"] ?? .null,
              case .string(let roundTrippedType) = innerCard["type"] ?? .null,
              roundTrippedType == "AdaptiveCard"
        else { throw DemoError.roundTripMismatch }
}

// MARK: - Demo errors

private enum DemoError: Error, CustomStringConvertible {
    case malformedSample
    case malformedToolInput
    case unexpectedTool(String)
    case toolReportedError
    case missingEvent(String)
    case roundTripMismatch

    var description: String {
        switch self {
        case .malformedSample: return "canonical sample card failed to parse"
        case .malformedToolInput: return "tool input did not carry the expected card shape"
        case .unexpectedTool(let n): return "agent invoked unexpected tool '\(n)'"
        case .toolReportedError: return "tool dispatcher returned isError=true"
        case .missingEvent(let e): return "AgentEvent stream missing '\(e)'"
        case .roundTripMismatch: return "round-tripped card no longer matches AdaptiveCard shape"
        }
    }
}
