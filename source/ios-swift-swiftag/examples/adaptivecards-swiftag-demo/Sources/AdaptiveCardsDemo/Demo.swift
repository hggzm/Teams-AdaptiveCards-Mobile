import Foundation
import SwiftAg

// Runtime symbol-check for the vendored SwiftAg snapshot. Flavor A
// (store): persist the canonical AdaptiveCards.io "Hello AdaptiveCards"
// sample as the content of an Agent ChatMessage, read it back through
// the agent's ConversationHistory transcript, and also round-trip it
// through a typed Tool registered in a ToolRegistry. The two
// observable PASS lines below are what smoke.ps1 / smoke.sh grep for.
//
// Symbols exercised (all from the vendored SwiftAg target):
//   - AgentIdentity.init(name:systemMessage:description:)
//   - ConversableAgent.init(identity:provider:history:...)
//   - ConversableAgent.send(_:to:)
//   - ConversableAgent.transcript()
//   - ChatMessage.init(role:content:name:toolCallID:)
//   - InMemoryHistory.init(initial:)
//   - ToolRegistry.register(_:)
//   - ToolRegistry.invoke(name:argumentsJSON:)
//   - Tool (protocol conformance via CardEchoTool below)
//
// Anything that prints "PASS adaptivecards-swiftag-..." is the
// observable outcome the smoke scripts assert on.

// A minimal Tool that echoes the AdaptiveCard JSON unchanged.
// Exists solely to exercise SwiftAg's Tool / ToolRegistry / AnyTool
// JSON-on-the-wire path against a real payload.
struct CardEchoInput: Codable, Sendable {
    var card: String
}

struct CardEchoOutput: Codable, Sendable {
    var card: String
}

struct CardEchoTool: Tool {
    typealias Input = CardEchoInput
    typealias Output = CardEchoOutput
    let name = "echo_card"
    let description = "Return the supplied AdaptiveCard JSON verbatim."
    let inputSchemaJSON =
        #"{"type":"object","properties":{"card":{"type":"string"}},"required":["card"]}"#

    func invoke(_ input: CardEchoInput) async throws -> CardEchoOutput {
        CardEchoOutput(card: input.card)
    }
}

@main
struct AdaptiveCardsDemo {
    static func main() async throws {
        let card = SampleCard.json

        // ----- Round-trip 1: store the card in an Agent transcript -----
        let writer = ConversableAgent(
            identity: AgentIdentity(
                name: "card-writer",
                systemMessage: "Persist AdaptiveCard payloads as messages."
            )
        )
        let reader = ConversableAgent(
            identity: AgentIdentity(name: "card-reader"),
            history: InMemoryHistory()
        )

        let stored = ChatMessage(
            role: .user,
            content: card,
            name: "card-writer"
        )
        try await writer.send(stored, to: reader)

        let transcript = await reader.transcript()
        guard let recovered = transcript.last?.content,
              recovered == card else {
            FileHandle.standardError.write(Data(
                "FAIL adaptivecards-swiftag-roundtrip: transcript mismatch\n".utf8
            ))
            exit(1)
        }
        print("PASS adaptivecards-swiftag-roundtrip")

        // ----- Round-trip 2: same card through ToolRegistry -----
        let registry = ToolRegistry()
        await registry.register(CardEchoTool())

        // Encode the card as the tool's JSON input.
        let argsData = try JSONEncoder()
            .encode(CardEchoInput(card: card))
        guard let argsJSON = String(data: argsData, encoding: .utf8) else {
            FileHandle.standardError.write(Data(
                "FAIL adaptivecards-swiftag-tool: could not UTF-8 encode args\n".utf8
            ))
            exit(1)
        }

        let toolJSON = try await registry.invoke(
            name: "echo_card",
            argumentsJSON: argsJSON
        )

        guard let toolData = toolJSON.data(using: .utf8) else {
            FileHandle.standardError.write(Data(
                "FAIL adaptivecards-swiftag-tool: could not UTF-8 decode result\n".utf8
            ))
            exit(1)
        }
        let toolOut = try JSONDecoder().decode(CardEchoOutput.self, from: toolData)
        guard toolOut.card == card else {
            FileHandle.standardError.write(Data(
                "FAIL adaptivecards-swiftag-tool: tool output mismatch\n".utf8
            ))
            exit(1)
        }
        print("PASS adaptivecards-swiftag-tool")
    }
}
