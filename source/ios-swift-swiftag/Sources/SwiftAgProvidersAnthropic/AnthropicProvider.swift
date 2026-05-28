import Foundation
import SwiftAg

/// Phase-1 Anthropic provider stub. Real `messages` HTTP wiring lands
/// alongside streaming in Phase 4. The placeholder exists so the
/// product target shape is stable from day one.
public struct AnthropicProvider: LLMProvider {
    public let config: LLMConfig

    public init(config: LLMConfig) {
        precondition(config.provider == "anthropic",
                     "AnthropicProvider requires provider=\"anthropic\", got \(config.provider)")
        self.config = config
    }

    public func complete(messages: [ChatMessage]) async throws -> LLMResponse {
        throw AnthropicProviderError.notYetImplemented(
            "AnthropicProvider lands in Phase 4."
        )
    }
}

public enum AnthropicProviderError: Error, Sendable, Equatable {
    case notYetImplemented(String)
    case missingAPIKey
}
