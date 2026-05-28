// Context — the immutable per-turn input handed to a Provider.

public struct Context: Codable, Sendable, Equatable {
    /// Optional system prompt prepended to the conversation.
    public let system: String?

    /// Conversation history, oldest-first, already compacted if needed.
    public let messages: [Message]

    /// Tool definitions available to the assistant on this turn.
    public let tools: [ToolDef]

    public init(
        system: String? = nil,
        messages: [Message] = [],
        tools: [ToolDef] = []
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}
