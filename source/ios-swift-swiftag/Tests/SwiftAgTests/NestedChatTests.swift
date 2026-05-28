import XCTest
@testable import SwiftAg

final class NestedChatTests: XCTestCase {
    func testNestedReplySurfacesLastInnerMessage() async throws {
        let inner1 = ConversableAgent(identity: AgentIdentity(name: "inner1"))
        let inner2 = ConversableAgent(identity: AgentIdentity(name: "inner2"))
        let nested = NestedChat(
            identity: AgentIdentity(name: "researcher"),
            agents: [inner1, inner2],
            pattern: RoundRobinPattern(),
            maxRounds: 2
        )
        // Outer caller delivers a message.
        try await nested.receive(
            ChatMessage(role: .user, content: "investigate"),
            from: inner1
        )
        let reply = try await nested.generateReply(to: nil)
        guard case let .message(m) = reply else {
            return XCTFail("expected .message, got \(reply)")
        }
        XCTAssertEqual(m.name, "researcher")
        XCTAssertFalse(m.content.isEmpty)
    }

    func testNestedChatComposesInsideGroupChat() async throws {
        // Outer: planner <-> researcher, where researcher is itself
        // a NestedChat over two inner agents.
        let planner = ConversableAgent(identity: AgentIdentity(name: "planner"))
        let inner1  = ConversableAgent(identity: AgentIdentity(name: "inner1"))
        let inner2  = ConversableAgent(identity: AgentIdentity(name: "inner2"))
        let researcher = NestedChat(
            identity: AgentIdentity(name: "researcher"),
            agents: [inner1, inner2],
            pattern: RoundRobinPattern(),
            maxRounds: 2
        )
        let outer = GroupChat(
            agents: [planner, researcher],
            pattern: RoundRobinPattern(),
            maxRounds: 2
        )
        let transcript = try await outer.run(
            initialMessage: ChatMessage(role: .user, content: "research circuits")
        )
        // Opener + 2 outer replies.
        XCTAssertEqual(transcript.count, 3)
        XCTAssertEqual(transcript.last?.name, "researcher")
    }
}
