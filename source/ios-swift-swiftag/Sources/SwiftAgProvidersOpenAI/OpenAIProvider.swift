import Foundation
import SwiftAg

/// Phase-1 OpenAI provider. Conforms to `LLMProvider` and validates
/// configuration eagerly, but the actual `chat.completions` HTTP wiring
/// (request encoding, streaming, tool-call decoding) lands in a later
/// phase together with the SwiftNIO + async-http-client substrate.
///
/// For now `complete(messages:)` will throw if no canned response has
/// been injected via `OpenAIProvider.testing(...)`. This keeps the
/// surface area honest while letting `SwiftAg` exercise the protocol
/// in unit tests with deterministic fakes.
public struct OpenAIProvider: LLMProvider {
    public let config: LLMConfig
    private let canned: (@Sendable ([ChatMessage]) async throws -> LLMResponse)?

    public init(config: LLMConfig) {
        precondition(config.provider == "openai",
                     "OpenAIProvider requires provider=\"openai\", got \(config.provider)")
        self.config = config
        self.canned = nil
    }

    /// Test/preview constructor that bypasses the network and returns
    /// whatever `respond` produces. Used by SwiftAgTests and by
    /// callers experimenting with conversational flows offline.
    public static func testing(
        config: LLMConfig = LLMConfig(provider: "openai", model: "test"),
        respond: @escaping @Sendable ([ChatMessage]) async throws -> LLMResponse
    ) -> OpenAIProvider {
        OpenAIProvider(_config: config, canned: respond)
    }

    private init(
        _config: LLMConfig,
        canned: (@Sendable ([ChatMessage]) async throws -> LLMResponse)?
    ) {
        self.config = _config
        self.canned = canned
    }

    public func complete(messages: [ChatMessage]) async throws -> LLMResponse {
        if let canned {
            return try await canned(messages)
        }
        throw OpenAIProviderError.notYetImplemented(
            "OpenAIProvider HTTP path lands in a later phase; use OpenAIProvider.testing(...) for now."
        )
    }
}

public enum OpenAIProviderError: Error, Sendable, Equatable {
    case notYetImplemented(String)
    case missingAPIKey
}
