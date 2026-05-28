
import Foundation
import NIO
import NIOHTTP1
import Testing
@testable import SwiftPiCore
@testable import SwiftPiProviders

@Suite("AnthropicProvider — request body encoding")
struct AnthropicProviderRequestBodyTests {
    @Test("encodes model, max_tokens, stream=true, and messages as snake_case")
    func basicRequestBody() throws {
        let context = Context(
            system: "You are helpful.",
            messages: [
                Message(id: "u1", role: .user, content: [.text("hi")])
            ],
            tools: []
        )
        let options = StreamOptions(model: "claude-sonnet-4-6", maxTokens: 1024)
        let data = try AnthropicProvider.encodeRequestBody(
            context: context,
            options: options
        )
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("\"model\":\"claude-sonnet-4-6\""))
        #expect(raw.contains("\"max_tokens\":1024"))
        #expect(raw.contains("\"stream\":true"))
        #expect(raw.contains("\"system\":\"You are helpful.\""))
        // messages array must contain a user role with the text block.
        #expect(raw.contains("\"role\":\"user\""))
        #expect(raw.contains("\"text\":\"hi\""))
    }

    @Test("optional temperature, stop_sequences, thinking, and tools are emitted only when set")
    func optionalFields() throws {
        // None of the optional knobs supplied — body should not contain
        // those keys.
        let bareData = try AnthropicProvider.encodeRequestBody(
            context: Context(),
            options: StreamOptions(model: "x", maxTokens: 1)
        )
        let bare = String(decoding: bareData, as: UTF8.self)
        #expect(!bare.contains("\"temperature\""))
        #expect(!bare.contains("\"stop_sequences\""))
        #expect(!bare.contains("\"thinking\""))
        #expect(!bare.contains("\"tools\""))

        // All knobs supplied — keys present, snake_case.
        let context = Context(
            tools: [
                ToolDef(
                    name: "read",
                    description: "read a file",
                    inputSchema: .object(["type": .string("object")])
                )
            ]
        )
        let options = StreamOptions(
            model: "x",
            maxTokens: 1,
            temperature: 0.3,
            thinking: ThinkingConfig(level: .medium, budgetTokens: 2048),
            stopSequences: ["\n\n"]
        )
        let fullData = try AnthropicProvider.encodeRequestBody(
            context: context,
            options: options
        )
        let full = String(decoding: fullData, as: UTF8.self)
        #expect(full.contains("\"temperature\":0.3"))
        #expect(full.contains("\"stop_sequences\""))
        #expect(full.contains("\"thinking\""))
        #expect(full.contains("\"budget_tokens\":2048"))
        #expect(full.contains("\"tools\""))
        #expect(full.contains("\"input_schema\""))
        #expect(full.contains("\"name\":\"read\""))
    }

    @Test("system role messages are NOT included in the messages array")
    func systemRoleStrippedFromMessages() throws {
        let context = Context(
            messages: [
                Message(id: "s", role: .system, content: [.text("ignored")]),
                Message(id: "u", role: .user, content: [.text("kept")]),
            ]
        )
        let data = try AnthropicProvider.encodeRequestBody(
            context: context,
            options: StreamOptions(model: "x", maxTokens: 1)
        )
        let raw = String(decoding: data, as: UTF8.self)
        #expect(!raw.contains("ignored"))
        #expect(raw.contains("kept"))
    }
}

@Suite("AnthropicProvider — fixture-server roundtrip")
struct AnthropicProviderRoundtripTests {
    private let textTurnSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_abc","role":"assistant"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    @Test("happy path: provider yields the decoded StreamEvent sequence")
    func happyPath() async throws {
        let server = try await FixtureSSEServer.start(
            .init(body: textTurnSSE)
        )
        defer {
            Task { try? await server.shutdown() }
        }
        try await withAnthropicProvider(
            apiKey: "test-key",
            baseURL: server.baseURL
        ) { provider in
            var collected: [StreamEvent] = []
            for try await event in provider.stream(
                context: Context(messages: [
                    Message(id: "u", role: .user, content: [.text("hi")])
                ]),
                options: StreamOptions(model: "claude-x", maxTokens: 32)
            ) {
                collected.append(event)
            }
            // Stream ended with message_stop.
            #expect(collected.last == .messageStop)
            // The concatenated text_delta payload is "Hello world".
            let concatText = collected.compactMap { event -> String? in
                if case .contentBlockDelta(let p) = event {
                    return p.delta.objectValue?["text"]?.stringValue
                }
                return nil
            }.joined()
            #expect(concatText == "Hello world")
        }
    }

    @Test("non-2xx response is surfaced as SwiftPiError.providerRejected")
    func nonSuccessfulStatus() async throws {
        let server = try await FixtureSSEServer.start(
            .init(
                status: .tooManyRequests,
                body: "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
                contentType: "application/json"
            )
        )
        defer {
            Task { try? await server.shutdown() }
        }
        try await withAnthropicProvider(
            apiKey: "test-key",
            baseURL: server.baseURL
        ) { provider in
            var threwProviderRejected = false
            do {
                for try await _ in provider.stream(
                    context: Context(),
                    options: StreamOptions(model: "x", maxTokens: 1)
                ) {
                    // drain
                }
            } catch let error as SwiftPiError {
                if case .providerRejected(let code, _) = error {
                    #expect(code == 429)
                    threwProviderRejected = true
                }
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
            #expect(threwProviderRejected)
        }
    }
}
