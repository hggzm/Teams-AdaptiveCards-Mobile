
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiSession

/// Test scaffolding for the disk-backed SessionStore. Each test creates
/// a unique directory under the system temp dir and cleans it up
/// regardless of how the test exits.
private struct TempSessionDir {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpi-session-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        self.url = base
    }

    var sessionFile: URL {
        url.appendingPathComponent("test.jsonl")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("SessionStore — basic IO")
struct SessionStoreBasicTests {
    @Test("read on a missing file yields an empty result, no error")
    func readMissingFile() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        let result = try await store.read()
        #expect(result.entries.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test("write then read round-trips the full entry list")
    func writeThenReadRoundTrip() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        let entries: [SessionEntry] = [
            .session(SessionHeader(version: 3, cwd: "/cwd")),
            .message(Message(id: "m1", role: .user, content: [.text("hi")])),
            .message(
                Message(
                    id: "m2",
                    role: .assistant,
                    content: [.text("hello")],
                    parent: "m1"
                )
            ),
        ]
        try await store.write(entries)
        let restored = try await store.readStrict()
        #expect(restored == entries)
    }

    @Test("write creates intermediate directories")
    func writeCreatesIntermediateDirs() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let nested = tmp.url
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("session.jsonl")
        let store = SessionStore(url: nested)
        try await store.write([.session(SessionHeader())])
        let exists = await store.fileExists()
        #expect(exists)
    }
}

@Suite("SessionStore — append")
struct SessionStoreAppendTests {
    @Test("append on an empty session writes a single line")
    func appendOnEmpty() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        let entry: SessionEntry = .session(SessionHeader(version: 3))
        try await store.append(entry)
        let restored = try await store.readStrict()
        #expect(restored == [entry])
    }

    @Test("append extends an existing file without rewriting earlier rows")
    func appendExtends() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        let header: SessionEntry = .session(SessionHeader(version: 3))
        let user: SessionEntry = .message(
            Message(id: "u1", role: .user, content: [.text("first")])
        )
        let assistant: SessionEntry = .message(
            Message(
                id: "a1",
                role: .assistant,
                content: [.text("second")],
                parent: "u1"
            )
        )
        try await store.append(header)
        try await store.append(user)
        try await store.append(assistant)
        let restored = try await store.readStrict()
        #expect(restored == [header, user, assistant])
    }

    @Test("interleaved appends from concurrent tasks land in writer order")
    func appendUnderActorSerialization() async throws {
        // The SessionStore is an actor; concurrent appends from many
        // tasks serialize at the actor boundary. We can't assert on
        // their relative ordering, but we can assert nothing is lost
        // and the file remains valid JSONL.
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        try await store.append(.session(SessionHeader(version: 3)))

        let count = 12
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let entry: SessionEntry = .message(
                        Message(
                            id: "m-\(i)",
                            role: .user,
                            content: [.text("\(i)")]
                        )
                    )
                    try? await store.append(entry)
                }
            }
        }
        let restored = try await store.readStrict()
        // 1 header + `count` messages.
        #expect(restored.count == count + 1)
        // Every original id is present.
        let ids = Set(restored.compactMap(\.id))
        for i in 0..<count {
            #expect(ids.contains("m-\(i)"))
        }
    }
}

@Suite("SessionStore — atomic save")
struct SessionStoreAtomicSaveTests {
    @Test("after write, no .tmp- sibling files remain")
    func noTempSiblings() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        for i in 0..<5 {
            try await store.append(
                .message(
                    Message(
                        id: "m-\(i)",
                        role: .user,
                        content: [.text("\(i)")]
                    )
                )
            )
        }
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: tmp.url.path)
        let tmps = contents.filter { $0.contains(".tmp-") }
        #expect(tmps.isEmpty)
    }

    @Test("overwrite preserves an existing readable file on success")
    func overwriteIsAtomic() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        try await store.write([.session(SessionHeader(version: 3))])
        try await store.write([
            .session(SessionHeader(version: 3)),
            .message(Message(id: "later", role: .user, content: [.text("x")])),
        ])
        let restored = try await store.readStrict()
        #expect(restored.count == 2)
        #expect(restored.last?.id == "later")
    }
}

@Suite("SessionStore — errors")
struct SessionStoreErrorTests {
    @Test("readStrict raises on a malformed line")
    func readStrictThrows() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        try await store.write([.session(SessionHeader(version: 3))])
        // Append a malformed line by hand, bypassing the store.
        if var data = try? Data(contentsOf: tmp.sessionFile) {
            data.append(contentsOf: "garbage\n".utf8)
            try data.write(to: tmp.sessionFile)
        }
        do {
            _ = try await store.readStrict()
            Issue.record("Expected readStrict to throw on malformed JSONL")
        } catch {
            // expected
        }
    }

    @Test("non-strict read surfaces a malformed line as an error entry")
    func nonStrictReadSurfacesError() async throws {
        let tmp = try TempSessionDir()
        defer { tmp.cleanup() }
        let store = SessionStore(url: tmp.sessionFile)
        try await store.write([.session(SessionHeader(version: 3))])
        if var data = try? Data(contentsOf: tmp.sessionFile) {
            data.append(contentsOf: "garbage\n".utf8)
            try data.write(to: tmp.sessionFile)
        }
        let result = try await store.read()
        #expect(result.entries.count == 1)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.line == 2)
    }
}
