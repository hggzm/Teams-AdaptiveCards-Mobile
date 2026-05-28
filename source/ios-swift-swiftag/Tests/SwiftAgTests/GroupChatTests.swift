import XCTest
@testable import SwiftAg

/// Synchronous test double that always emits a termination message.
private final class Terminator: Agent, @unchecked Sendable {
    let identity = AgentIdentity(name: "terminator")
    func receive(_ message: ChatMessage, from sender: Agent) async throws {}
    func generateReply(to recipient: Agent?) async throws -> AgentReply {
        .message(ChatMessage(role: .assistant, content: "stop. TERMINATE", name: "terminator"))
    }
    func isTerminationMessage(_ message: ChatMessage) -> Bool { true }
}

final class GroupChatTests: XCTestCase {
    func testRoundRobinCyclesThroughAgents() async {
        let pattern = RoundRobinPattern()
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let agents: [Agent] = [a, b]
        let first  = await pattern.selectNext(agents: agents, history: [])
        let second = await pattern.selectNext(agents: agents, history: [])
        let third  = await pattern.selectNext(agents: agents, history: [])
        XCTAssertTrue(first === a)
        XCTAssertTrue(second === b)
        XCTAssertTrue(third === a)
    }

    func testRoundRobinEmptyAgentsReturnsNil() async {
        let pattern = RoundRobinPattern()
        let pick = await pattern.selectNext(agents: [], history: [])
        XCTAssertNil(pick)
    }

    func testGroupChatRunsMaxRoundsReplies() async throws {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let chat = GroupChat(agents: [a, b], pattern: RoundRobinPattern(), maxRounds: 4)
        let transcript = try await chat.run(
            initialMessage: ChatMessage(role: .user, content: "go")
        )
        // 1 opener + 4 replies
        XCTAssertEqual(transcript.count, 5)
        XCTAssertEqual(transcript.first?.content, "go")
    }

    func testGroupChatHaltsOnTerminationMessage() async throws {
        let chat = GroupChat(
            agents: [Terminator()],
            pattern: RoundRobinPattern(),
            maxRounds: 100
        )
        let transcript = try await chat.run(
            initialMessage: ChatMessage(role: .user, content: "go")
        )
        XCTAssertEqual(transcript.count, 2)
        XCTAssertTrue(transcript.last!.content.contains("TERMINATE"))
    }

    func testGroupChatBroadcastsToOtherAgents() async throws {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let chat = GroupChat(agents: [a, b], pattern: RoundRobinPattern(), maxRounds: 2)
        _ = try await chat.run(initialMessage: ChatMessage(role: .user, content: "go"))
        let aSeen = await a.transcript()
        let bSeen = await b.transcript()
        // Each agent receives the opener + (after speaking) the peer's reply,
        // plus their own appended reply via generateReply.
        XCTAssertGreaterThanOrEqual(aSeen.count, 2)
        XCTAssertGreaterThanOrEqual(bSeen.count, 2)
    }
}
