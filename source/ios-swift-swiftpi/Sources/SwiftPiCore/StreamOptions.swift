// StreamOptions — knobs supplied to a Provider for a single streamed
// completion. Stable across providers; per-provider extensions live in
// SwiftPiProviders.

public struct StreamOptions: Codable, Sendable, Equatable {
    public let model: String
    public let maxTokens: Int
    public let temperature: Double?
    public let thinking: ThinkingConfig?
    public let stopSequences: [String]

    public init(
        model: String,
        maxTokens: Int,
        temperature: Double? = nil,
        thinking: ThinkingConfig? = nil,
        stopSequences: [String] = []
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinking = thinking
        self.stopSequences = stopSequences
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case temperature
        case thinking
        case stopSequences = "stop_sequences"
    }
}
