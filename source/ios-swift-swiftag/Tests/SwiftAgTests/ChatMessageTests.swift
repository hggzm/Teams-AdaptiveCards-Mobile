import XCTest
@testable import SwiftAg

final class ChatMessageTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let msg = ChatMessage(role: .user, content: "hello", name: "alice")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testRoleRawValues() {
        XCTAssertEqual(ChatRole.system.rawValue, "system")
        XCTAssertEqual(ChatRole.user.rawValue, "user")
        XCTAssertEqual(ChatRole.assistant.rawValue, "assistant")
        XCTAssertEqual(ChatRole.tool.rawValue, "tool")
        XCTAssertEqual(ChatRole.allCases.count, 4)
    }

    func testToolCallIDOmittedWhenNil() throws {
        let msg = ChatMessage(role: .assistant, content: "hi")
        let json = String(data: try JSONEncoder().encode(msg), encoding: .utf8)!
        XCTAssertFalse(json.contains("toolCallID"))
        XCTAssertFalse(json.contains("name"))
    }

    func testTerminationDetectionDefault() {
        let agent = ConversableAgent(identity: AgentIdentity(name: "x"))
        XCTAssertTrue(agent.isTerminationMessage(
            ChatMessage(role: .assistant, content: "done. TERMINATE")
        ))
        XCTAssertTrue(agent.isTerminationMessage(
            ChatMessage(role: .assistant, content: "  terminate  \n")
        ))
        XCTAssertFalse(agent.isTerminationMessage(
            ChatMessage(role: .assistant, content: "still going")
        ))
    }
}
