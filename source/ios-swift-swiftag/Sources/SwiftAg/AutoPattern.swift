import Foundation

/// `AutoPattern` consults an `LLMProvider` to pick the next speaker
/// in a group chat. The provider receives a short system prompt
/// listing the available agents and the running transcript, and is
/// expected to reply with the speaker's name (case-insensitive match).
/// If the reply doesn't match any agent, falls back to round-robin
/// over `agents`.
public actor AutoPattern: GroupChatPattern {
    private let provider: any LLMProvider
    private var fallbackIndex = 0

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    public func selectNext(agents: [Agent], history: [ChatMessage]) async -> Agent? {
        guard !agents.isEmpty else { return nil }

        let roster = agents.map(\.identity.name).joined(separator: ", ")
        let prompt = ChatMessage(
            role: .system,
            content: """
            You are the moderator of a multi-agent conversation. The next \
            speaker must be exactly one of: \(roster). Reply with only \
            that agent's name and nothing else.
            """
        )

        var messages: [ChatMessage] = [prompt]
        messages.append(contentsOf: history)

        if let response = try? await provider.complete(messages: messages) {
            let pick = response.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let match = agents.first(where: { $0.identity.name.lowercased() == pick }) {
                return match
            }
        }

        // Fallback: deterministic round-robin so the chat still advances.
        let agent = agents[fallbackIndex % agents.count]
        fallbackIndex += 1
        return agent
    }
}
