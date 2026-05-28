import XCTest
@testable import SwiftAg

final class InMemoryHistoryTests: XCTestCase {
    func testAppendAndAll() async {
        let h = InMemoryHistory()
        await h.append(ChatMessage(role: .user, content: "a"))
        await h.append(ChatMessage(role: .assistant, content: "b"))
        let all = await h.all()
        XCTAssertEqual(all.map(\.content), ["a", "b"])
    }

    func testClear() async {
        let h = InMemoryHistory(initial: [
            ChatMessage(role: .system, content: "sys")
        ])
        let before = await h.all()
        XCTAssertEqual(before.count, 1)
        await h.clear()
        let after = await h.all()
        XCTAssertEqual(after.count, 0)
    }

    func testInitialMessages() async {
        let seed = [
            ChatMessage(role: .system, content: "you are a tester"),
            ChatMessage(role: .user, content: "hello"),
        ]
        let h = InMemoryHistory(initial: seed)
        let all = await h.all()
        XCTAssertEqual(all, seed)
    }
}
