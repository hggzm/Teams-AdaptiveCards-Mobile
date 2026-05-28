// Thinking configuration types.

public enum ThinkingLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
}

/// Thinking configuration passed to a provider on a streamed request.
/// Maps to Anthropic's `thinking` field.
public struct ThinkingConfig: Codable, Sendable, Equatable {
    public let level: ThinkingLevel
    public let budgetTokens: Int?

    public init(level: ThinkingLevel, budgetTokens: Int? = nil) {
        self.level = level
        self.budgetTokens = budgetTokens
    }

    enum CodingKeys: String, CodingKey {
        case level
        case budgetTokens = "budget_tokens"
    }
}
