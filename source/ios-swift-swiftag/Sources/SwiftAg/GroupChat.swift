import Foundation

/// Strategy that picks the next speaker in a `GroupChat`. Stateful
/// strategies (round-robin, last-speaker-then-other, etc.) are
/// modelled as actors so `selectNext` can mutate cursor state.
public protocol GroupChatPattern: Sendable {
    func selectNext(agents: [Agent], history: [ChatMessage]) async -> Agent?
}

/// Cycles through `agents` in order, advancing one position per call.
public actor RoundRobinPattern: GroupChatPattern {
    private var index = 0

    public init() {}

    public func selectNext(agents: [Agent], history: [ChatMessage]) -> Agent? {
        guard !agents.isEmpty else { return nil }
        let pick = agents[index % agents.count]
        index += 1
        return pick
    }
}

/// Orchestrates a multi-agent conversation. Conforms to `Agent` so it
/// can be its own broadcast origin when delivering the opening message
/// and inter-agent messages.
public actor GroupChat: Agent {
    public nonisolated let identity: AgentIdentity
    private let agents: [Agent]
    private let pattern: any GroupChatPattern
    private let history: any ConversationHistory
    private let maxRounds: Int

    public init(
        name: String = "_groupchat",
        agents: [Agent],
        pattern: any GroupChatPattern,
        history: any ConversationHistory = InMemoryHistory(),
        maxRounds: Int = 10
    ) {
        self.identity = AgentIdentity(name: name)
        self.agents = agents
        self.pattern = pattern
        self.history = history
        self.maxRounds = maxRounds
    }

    public func transcript() async -> [ChatMessage] {
        await history.all()
    }

    // MARK: - Agent

    public nonisolated func isTerminationMessage(_ message: ChatMessage) -> Bool {
        message.content
            .uppercased()
            .contains("TERMINATE")
    }

    public func receive(_ message: ChatMessage, from sender: Agent) async throws {
        await history.append(message)
    }

    public func generateReply(to recipient: Agent?) async throws -> AgentReply {
        .none
    }

    // MARK: - Orchestration

    /// Run the group chat from an opening message. Returns the full
    /// transcript (opener + every reply produced). Halts at the first
    /// of: a `.terminate` reply, a message detected as a termination
    /// message, or after `maxRounds` rounds.
    public func run(initialMessage: ChatMessage) async throws -> [ChatMessage] {
        await history.append(initialMessage)
        for agent in agents {
            try await agent.receive(initialMessage, from: self)
        }

        for _ in 0..<maxRounds {
            let snapshot = await history.all()
            guard let speaker = await pattern.selectNext(agents: agents, history: snapshot) else {
                break
            }
            let reply = try await speaker.generateReply(to: nil)
            switch reply {
            case .none:
                continue
            case .terminate:
                return await history.all()
            case .message(let m):
                await history.append(m)
                for agent in agents where agent !== speaker {
                    try await agent.receive(m, from: speaker)
                }
                if isTerminationMessage(m) {
                    return await history.all()
                }
            }
        }
        return await history.all()
    }
}
