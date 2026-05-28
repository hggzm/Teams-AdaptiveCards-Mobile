import Foundation

/// Errors raised by ConversableAgent's reply pipeline.
public enum ConversableAgentError: Error, Sendable, Equatable {
    case noProviderConfigured
    case providerFailure(String)
}

/// Concrete actor-backed agent that can hold a system prompt, append
/// to a history, and produce replies either by echoing or by
/// delegating to an `LLMProvider`.
///
/// The shape is intentionally close to AG2's `ConversableAgent`
/// behaviour as documented at https://docs.ag2.ai/, but every byte
/// here is independently authored.
public actor ConversableAgent: Agent {
    public nonisolated let identity: AgentIdentity
    public nonisolated let humanInputMode: HumanInputMode

    private let provider: LLMProvider?
    private let history: any ConversationHistory
    private let maxConsecutiveAutoReply: Int
    private var consecutiveAutoReplies: Int = 0

    public init(
        identity: AgentIdentity,
        provider: LLMProvider? = nil,
        history: any ConversationHistory = InMemoryHistory(),
        humanInputMode: HumanInputMode = .never,
        maxConsecutiveAutoReply: Int = 10
    ) {
        self.identity = identity
        self.provider = provider
        self.history = history
        self.humanInputMode = humanInputMode
        self.maxConsecutiveAutoReply = maxConsecutiveAutoReply
    }

    /// Snapshot of the conversation as this agent sees it.
    public func transcript() async -> [ChatMessage] {
        await history.all()
    }

    /// Reset the conversation. Useful between test cases.
    public func reset() async {
        await history.clear()
        consecutiveAutoReplies = 0
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
        let messages = await history.all()
        guard let last = messages.last else { return .none }

        if isTerminationMessage(last) {
            return .terminate(reason: "termination message")
        }

        if consecutiveAutoReplies >= maxConsecutiveAutoReply {
            return .terminate(reason: "max consecutive auto replies reached")
        }

        let reply: ChatMessage
        if let provider {
            var prompt: [ChatMessage] = []
            if let sys = identity.systemMessage {
                prompt.append(ChatMessage(role: .system, content: sys, name: identity.name))
            }
            prompt.append(contentsOf: messages)
            do {
                let response = try await provider.complete(messages: prompt)
                reply = ChatMessage(
                    role: .assistant,
                    content: response.message.content,
                    name: identity.name
                )
            } catch {
                throw ConversableAgentError.providerFailure(String(describing: error))
            }
        } else {
            // Provider-less fallback: echo the last user message,
            // wrapped so the caller can see this agent participated.
            reply = ChatMessage(
                role: .assistant,
                content: "[\(identity.name)] echo: \(last.content)",
                name: identity.name
            )
        }

        await history.append(reply)
        consecutiveAutoReplies += 1
        return .message(reply)
    }
}
