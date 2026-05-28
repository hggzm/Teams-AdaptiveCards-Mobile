import XCTest
@testable import SwiftAg
@testable import SwiftAgProvidersOpenAI

final class ConversableAgentTests: XCTestCase {
    func testEchoFallbackWhenNoProvider() async throws {
        let alice = ConversableAgent(identity: AgentIdentity(name: "alice"))
        let bob   = ConversableAgent(identity: AgentIdentity(name: "bob"))

        let msg = ChatMessage(role: .user, content: "ping", name: "alice")
        try await alice.send(msg, to: bob)

        let reply = try await bob.generateReply(to: alice)
        guard case let .message(out) = reply else {
            return XCTFail("expected .message, got \(reply)")
        }
        XCTAssertEqual(out.role, .assistant)
        XCTAssertEqual(out.name, "bob")
        XCTAssertTrue(out.content.contains("ping"))
        XCTAssertTrue(out.content.contains("bob"))
    }

    func testProviderBackedReply() async throws {
        let provider = OpenAIProvider.testing { msgs in
            LLMResponse(
                message: ChatMessage(role: .assistant, content: "pong (\(msgs.count))")
            )
        }
        let agent = ConversableAgent(
            identity: AgentIdentity(name: "responder", systemMessage: "sys"),
            provider: provider
        )
        let user = ConversableAgent(identity: AgentIdentity(name: "user"))
        try await user.send(ChatMessage(role: .user, content: "hi"), to: agent)

        let reply = try await agent.generateReply(to: user)
        guard case let .message(out) = reply else {
            return XCTFail("expected .message")
        }
        // system + 1 user = 2 messages handed to provider
        XCTAssertEqual(out.content, "pong (2)")
        XCTAssertEqual(out.name, "responder")
    }

    func testTerminationMessageEndsConversation() async throws {
        let agent = ConversableAgent(identity: AgentIdentity(name: "a"))
        let peer  = ConversableAgent(identity: AgentIdentity(name: "p"))
        try await peer.send(
            ChatMessage(role: .user, content: "bye, TERMINATE"),
            to: agent
        )
        let reply = try await agent.generateReply(to: peer)
        guard case .terminate = reply else {
            return XCTFail("expected .terminate, got \(reply)")
        }
    }

    func testEmptyHistoryYieldsNone() async throws {
        let agent = ConversableAgent(identity: AgentIdentity(name: "a"))
        let reply = try await agent.generateReply(to: nil)
        XCTAssertEqual(reply, .none)
    }

    func testMaxConsecutiveAutoReplyEnforced() async throws {
        let agent = ConversableAgent(
            identity: AgentIdentity(name: "a"),
            maxConsecutiveAutoReply: 1
        )
        let peer = ConversableAgent(identity: AgentIdentity(name: "p"))
        try await peer.send(ChatMessage(role: .user, content: "one"), to: agent)
        _ = try await agent.generateReply(to: peer)

        try await peer.send(ChatMessage(role: .user, content: "two"), to: agent)
        let reply = try await agent.generateReply(to: peer)
        if case .terminate(let reason) = reply {
            XCTAssertTrue(reason.contains("max consecutive"))
        } else {
            XCTFail("expected termination after exceeding max replies, got \(reply)")
        }
    }

    func testResetClearsHistory() async throws {
        let agent = ConversableAgent(identity: AgentIdentity(name: "a"))
        let peer  = ConversableAgent(identity: AgentIdentity(name: "p"))
        try await peer.send(ChatMessage(role: .user, content: "x"), to: agent)
        let before = await agent.transcript()
        XCTAssertEqual(before.count, 1)
        await agent.reset()
        let after = await agent.transcript()
        XCTAssertEqual(after.count, 0)
    }

    func testProviderFailurePropagatesAsConversableAgentError() async throws {
        struct Boom: Error {}
        let provider = OpenAIProvider.testing { _ in throw Boom() }
        let agent = ConversableAgent(
            identity: AgentIdentity(name: "a"),
            provider: provider
        )
        let peer = ConversableAgent(identity: AgentIdentity(name: "p"))
        try await peer.send(ChatMessage(role: .user, content: "trigger"), to: agent)

        do {
            _ = try await agent.generateReply(to: peer)
            XCTFail("expected throw")
        } catch let ConversableAgentError.providerFailure(msg) {
            XCTAssertTrue(msg.contains("Boom"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
