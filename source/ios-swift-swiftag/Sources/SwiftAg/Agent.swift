import Foundation

/// How an agent solicits input from a human in the loop.
///
/// Mirrors the conceptual `human_input_mode` values documented for
/// AG2's ConversableAgent: `NEVER` (fully autonomous), `TERMINATE`
/// (ask only at termination conditions), `ALWAYS` (every turn).
public enum HumanInputMode: String, Codable, Sendable, CaseIterable {
    case never
    case terminate
    case always
}

/// Stable identity for an agent participating in a conversation.
public struct AgentIdentity: Codable, Sendable, Hashable {
    public var name: String
    public var systemMessage: String?
    public var description: String?

    public init(
        name: String,
        systemMessage: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.systemMessage = systemMessage
        self.description = description
    }
}

/// Outcome of a single reply attempt.
public enum AgentReply: Sendable, Equatable {
    /// The agent declined to produce a reply (control should pass on).
    case none
    /// The agent produced a chat message.
    case message(ChatMessage)
    /// The agent terminated the conversation.
    case terminate(reason: String)
}

/// Protocol every agent conforms to.
///
/// Agents are reference-style participants — they are expected to
/// maintain history and may be backed by actors. The protocol itself
/// only describes the wire-level contract used by `GroupChat` and
/// peer-to-peer exchanges.
public protocol Agent: AnyObject, Sendable {
    var identity: AgentIdentity { get }

    /// Deliver `message` to this agent from `sender`. Implementations
    /// typically append the message to their history.
    func receive(_ message: ChatMessage, from sender: Agent) async throws

    /// Ask this agent to produce a reply, optionally to `recipient`.
    /// May return `.none` if the agent declines to speak.
    func generateReply(to recipient: Agent?) async throws -> AgentReply

    /// Predicate used to detect a terminating message in the
    /// transcript (e.g. literal "TERMINATE").
    func isTerminationMessage(_ message: ChatMessage) -> Bool
}

public extension Agent {
    /// Send a message from `self` to `recipient`. Default implementation
    /// just hands it off via `receive`.
    func send(_ message: ChatMessage, to recipient: Agent) async throws {
        try await recipient.receive(message, from: self)
    }

    func isTerminationMessage(_ message: ChatMessage) -> Bool {
        message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasSuffix("TERMINATE")
    }
}
