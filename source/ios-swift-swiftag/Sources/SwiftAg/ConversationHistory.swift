import Foundation

/// Storage protocol for a single agent's conversation history.
public protocol ConversationHistory: Sendable {
    func append(_ message: ChatMessage) async
    func all() async -> [ChatMessage]
    func clear() async
}

/// In-memory append-only history. Suitable for tests and short-lived
/// agents. For persistence, supply a different `ConversationHistory`.
public actor InMemoryHistory: ConversationHistory {
    private var messages: [ChatMessage] = []

    public init(initial: [ChatMessage] = []) {
        self.messages = initial
    }

    public func append(_ message: ChatMessage) { messages.append(message) }
    public func all() -> [ChatMessage] { messages }
    public func clear() { messages.removeAll() }
}
