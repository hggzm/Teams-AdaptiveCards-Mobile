import XCTest
@testable import SwiftAg

final class SwarmPatternTests: XCTestCase {
    func testParseHandoffBasic() {
        XCTAssertEqual(SwarmPattern.parseHandoff(from: "stuff HANDOFF: bob and more"), "bob")
        XCTAssertEqual(SwarmPattern.parseHandoff(from: "HANDOFF:alice"), "alice")
        XCTAssertNil(SwarmPattern.parseHandoff(from: "no marker"))
    }

    func testParseHandoffPreservesOriginalCasing() {
        XCTAssertEqual(SwarmPattern.parseHandoff(from: "handoff: AliceTheGreat"),
                       "AliceTheGreat")
    }

    func testInitialSpeakerWhenHistoryEmpty() async {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let pattern = SwarmPattern(initialSpeaker: "b")
        let pick = await pattern.selectNext(agents: [a, b], history: [])
        XCTAssertTrue(pick === b)
    }

    func testHandoffMarkerSelectsAgent() async {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let pattern = SwarmPattern(initialSpeaker: "a")
        let last = ChatMessage(role: .assistant,
                               content: "passing the baton. HANDOFF: b",
                               name: "a")
        let pick = await pattern.selectNext(agents: [a, b], history: [last])
        XCTAssertTrue(pick === b)
    }

    func testStickyWhenNoHandoff() async {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let b = ConversableAgent(identity: AgentIdentity(name: "b"))
        let pattern = SwarmPattern(initialSpeaker: "a")
        let last = ChatMessage(role: .assistant, content: "still talking", name: "a")
        let pick = await pattern.selectNext(agents: [a, b], history: [last])
        XCTAssertTrue(pick === a)
    }

    func testFallbackToFirstAgentWhenInitialUnknown() async {
        let a = ConversableAgent(identity: AgentIdentity(name: "a"))
        let pattern = SwarmPattern(initialSpeaker: "ghost")
        let pick = await pattern.selectNext(agents: [a], history: [])
        XCTAssertTrue(pick === a)
    }
}
