import XCTest
@testable import SwiftAg

final class UserProxyAgentTests: XCTestCase {
    func testScriptedInputProducesMessages() async throws {
        let source = ScriptedInputSource(["hello", "world"])
        let user = UserProxyAgent(
            identity: AgentIdentity(name: "user"),
            source: source,
            promptPrefix: ""
        )

        let r1 = try await user.generateReply(to: nil)
        guard case let .message(m1) = r1 else {
            return XCTFail("expected .message, got \(r1)")
        }
        XCTAssertEqual(m1.content, "hello")
        XCTAssertEqual(m1.role, .user)
        XCTAssertEqual(m1.name, "user")

        let r2 = try await user.generateReply(to: nil)
        guard case let .message(m2) = r2 else {
            return XCTFail("expected .message, got \(r2)")
        }
        XCTAssertEqual(m2.content, "world")
    }

    func testEOFTerminates() async throws {
        let source = ScriptedInputSource([])
        let user = UserProxyAgent(
            identity: AgentIdentity(name: "u"),
            source: source,
            promptPrefix: ""
        )
        let reply = try await user.generateReply(to: nil)
        if case .terminate(let reason) = reply {
            XCTAssertTrue(reason.contains("EOF"))
        } else {
            XCTFail("expected .terminate, got \(reply)")
        }
    }

    func testEmptyInputTerminates() async throws {
        let source = ScriptedInputSource([""])
        let user = UserProxyAgent(
            identity: AgentIdentity(name: "u"),
            source: source,
            promptPrefix: ""
        )
        let reply = try await user.generateReply(to: nil)
        if case .terminate = reply { } else { XCTFail("expected .terminate") }
    }

    func testExplicitTerminateMessage() async throws {
        let source = ScriptedInputSource(["all done. TERMINATE"])
        let user = UserProxyAgent(
            identity: AgentIdentity(name: "u"),
            source: source,
            promptPrefix: ""
        )
        let reply = try await user.generateReply(to: nil)
        if case .terminate = reply { } else { XCTFail("expected .terminate") }
    }

    func testPromptPrefixDelivered() async throws {
        let source = ScriptedInputSource(["x"])
        let user = UserProxyAgent(
            identity: AgentIdentity(name: "u"),
            source: source,
            promptPrefix: "say> "
        )
        _ = try await user.generateReply(to: nil)
        let prompts = await source.prompts
        XCTAssertEqual(prompts, ["say> "])
    }
}
