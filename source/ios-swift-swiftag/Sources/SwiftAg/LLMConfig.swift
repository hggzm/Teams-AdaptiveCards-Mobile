import Foundation

/// Configuration for an LLM call. Mirrors the conceptual shape of
/// AG2's `LLMConfig`/`OAI_CONFIG_LIST` entries without copying any of
/// its implementation.
public struct LLMConfig: Codable, Sendable, Hashable {
    /// Provider identifier, e.g. `"openai"`, `"anthropic"`.
    public var provider: String
    /// Model identifier as understood by the provider, e.g. `"gpt-4o"`.
    public var model: String
    /// Sampling temperature, 0.0–2.0 (provider-specific clamp).
    public var temperature: Double?
    /// Optional base URL override (for Azure / proxies / self-hosted).
    public var baseURL: URL?
    /// API key. Prefer loading from env via `LLMConfig.from(env:)`.
    public var apiKey: String?
    /// Free-form extra params forwarded to the provider.
    public var extra: [String: String]

    public init(
        provider: String,
        model: String,
        temperature: Double? = nil,
        baseURL: URL? = nil,
        apiKey: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.extra = extra
    }

    /// Build a config by reading conventional env vars for `provider`.
    ///
    /// - `openai`:    `OPENAI_API_KEY`,    `OPENAI_MODEL`    (default `gpt-4o-mini`)
    /// - `anthropic`: `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` (default `claude-3-5-sonnet-latest`)
    public static func from(
        env environment: [String: String] = ProcessInfo.processInfo.environment,
        provider: String
    ) -> LLMConfig {
        switch provider {
        case "openai":
            return LLMConfig(
                provider: "openai",
                model: environment["OPENAI_MODEL"] ?? "gpt-4o-mini",
                apiKey: environment["OPENAI_API_KEY"]
            )
        case "anthropic":
            return LLMConfig(
                provider: "anthropic",
                model: environment["ANTHROPIC_MODEL"] ?? "claude-3-5-sonnet-latest",
                apiKey: environment["ANTHROPIC_API_KEY"]
            )
        default:
            return LLMConfig(provider: provider, model: "")
        }
    }
}

/// A single tool call requested by an assistant message.
public struct LLMToolCall: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// JSON-encoded arguments, as supplied by the model.
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Result of one LLM completion.
public struct LLMResponse: Sendable, Equatable {
    public var message: ChatMessage
    public var toolCalls: [LLMToolCall]
    public var finishReason: String?

    public init(
        message: ChatMessage,
        toolCalls: [LLMToolCall] = [],
        finishReason: String? = nil
    ) {
        self.message = message
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

/// Provider-agnostic completion API. Each concrete provider lives in
/// its own target (`SwiftAgProvidersOpenAI`, `SwiftAgProvidersAnthropic`)
/// so callers opt in to the dependency surface they want.
public protocol LLMProvider: Sendable {
    var config: LLMConfig { get }

    /// Generate a single non-streaming completion for the given message
    /// transcript. Tool/schema wiring is added in a later phase.
    func complete(messages: [ChatMessage]) async throws -> LLMResponse
}
