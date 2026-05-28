import XCTest
@testable import SwiftAg
@testable import SwiftAgProvidersOpenAI

final class AutoPatternTests: XCTestCase {
    func testPicksAgentByName() async throws {
        let alice = ConversableAgent(identity: AgentIdentity(name: "alice"))
        let bob   = ConversableAgent(identity: AgentIdentity(name: "bob"))
        let provider = OpenAIProvider.testing { _ in
            LLMResponse(message: ChatMessage(role: .assistant, content: "bob"))
        }
        let pattern = AutoPattern(provider: provider)
        let pick = await pattern.selectNext(agents: [alice, bob], history: [])
        XCTAssertTrue(pick === bob)
    }

    func testCaseInsensitiveMatch() async throws {
        let alice = ConversableAgent(identity: AgentIdentity(name: "Alice"))
        let provider = OpenAIProvider.testing { _ in
            LLMResponse(message: ChatMessage(role: .assistant, content: "  ALICE  "))
        }
        let pattern = AutoPattern(provider: provider)
        let pick = await pattern.selectNext(agents: [alice], history: [])
        XCTAssertTrue(pick === alice)
    }

    func testFallbackToRoundRobinOnUnknownName() async throws {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let provider = OpenAIProvider.testing { _ in
            LLMResponse(message: ChatMessage(role: .assistant, content: "nobody"))
        }
        let pattern = AutoPattern(provider: provider)
        let first  = await pattern.selectNext(agents: [a, b], history: [])
        let second = await pattern.selectNext(agents: [a, b], history: [])
        XCTAssertTrue(first === a)
        XCTAssertTrue(second === b)
    }

    func testFallbackToRoundRobinOnProviderError() async throws {
        struct Boom: Error {}
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let provider = OpenAIProvider.testing { _ in throw Boom() }
        let pattern = AutoPattern(provider: provider)
        let first = await pattern.selectNext(agents: [a, b], history: [])
        XCTAssertTrue(first === a)
    }

    func testEmptyAgentsReturnsNil() async {
        let provider = OpenAIProvider.testing { _ in
            LLMResponse(message: ChatMessage(role: .assistant, content: "anyone"))
        }
        let pattern = AutoPattern(provider: provider)
        let pick = await pattern.selectNext(agents: [], history: [])
        XCTAssertNil(pick)
    }
}
