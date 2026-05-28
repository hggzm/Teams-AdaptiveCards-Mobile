import Foundation

/// Role of a chat message in an agent conversation.
///
/// Modelled after the public AG2 ConversableAgent docs: every message
/// carries one of these roles when handed to an LLM provider.
public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

/// A single chat message exchanged between agents (or between an agent
/// and an LLM provider).
public struct ChatMessage: Codable, Sendable, Hashable {
    public var role: ChatRole
    public var content: String
    /// Stable identifier of the sender. For LLM messages this is the
    /// agent name; for tool results, the tool name.
    public var name: String?
    /// Identifier echoed back from the provider when this message is a
    /// `tool` result responding to a previous tool call.
    public var toolCallID: String?

    public init(
        role: ChatRole,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
    }
}
