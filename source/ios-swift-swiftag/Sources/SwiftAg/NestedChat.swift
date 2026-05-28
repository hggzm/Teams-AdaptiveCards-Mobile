import Foundation

/// Agent whose `generateReply` runs an embedded `GroupChat` and
/// returns the last assistant message from the inner transcript.
/// Models AG2's nested-chat concept: an agent that is itself a small
/// conversation, exposed externally as a single speaker.
public actor NestedChat: Agent {
    public nonisolated let identity: AgentIdentity

    private let inner: GroupChat
    private let history: any ConversationHistory

    public init(
        identity: AgentIdentity,
        agents: [Agent],
        pattern: any GroupChatPattern,
        maxRounds: Int = 4,
        history: any ConversationHistory = InMemoryHistory()
    ) {
        self.identity = identity
        self.inner = GroupChat(
            name: "\(identity.name).inner",
            agents: agents,
            pattern: pattern,
            maxRounds: maxRounds
        )
        self.history = history
    }

    public func transcript() async -> [ChatMessage] {
        await history.all()
    }

    // MARK: - Agent

    nonisolated public func isTerminationMessage(_ message: ChatMessage) -> Bool {
        message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasSuffix("TERMINATE")
    }

    public func receive(_ message: ChatMessage, from sender: Agent) async throws {
        await history.append(message)
    }

    public func generateReply(to recipient: Agent?) async throws -> AgentReply {
        let outerHistory = await history.all()
        let opener = outerHistory.last ?? ChatMessage(role: .user, content: "")
        let inner = try await self.inner.run(initialMessage: opener)

        // Find the last non-opener message in the inner transcript;
        // attribute it to this NestedChat agent so the outer chat
        // sees one coherent speaker.
        guard let lastInner = inner.dropFirst().last else {
            return .none
        }
        let surfaced = ChatMessage(
            role: lastInner.role,
            content: lastInner.content,
            name: identity.name
        )
        await history.append(surfaced)
        return .message(surfaced)
    }
}
