
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiSession

// Free helpers are wrapped in an enum to dodge the Swift Testing
// per-suite-shadowing trap (see /memories/swift-testing-name-shadowing.md).
enum SessionTestHelpers {
    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func decodeJSON<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

@Suite("SessionEntry — Codable")
struct SessionEntryCodableTests {
    @Test("session header decodes from canonical v3 JSON")
    func sessionHeaderDecode() throws {
        let raw = """
        {"type":"session","version":3,"cwd":"/work/proj"}
        """
        let entry: SessionEntry = try SessionTestHelpers.decodeJSON(raw)
        guard case .session(let header) = entry else {
            Issue.record("Expected .session, got \(entry)")
            return
        }
        #expect(header.version == 3)
        #expect(header.cwd == "/work/proj")
        #expect(header.created == nil)
        #expect(entry.isHeader)
        #expect(entry.id == nil)
        #expect(entry.parent == nil)
    }

    @Test("session header round-trip with created timestamp")
    func sessionHeaderRoundTrip() throws {
        let header = SessionHeader(
            version: 3,
            cwd: "/work/proj",
            created: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let entry: SessionEntry = .session(header)
        let restored = try SessionTestHelpers.roundTrip(entry)
        #expect(restored == entry)
    }

    @Test("message entry round-trips with content blocks")
    func messageRoundTrip() throws {
        let message = Message(
            id: "msg-1",
            role: .user,
            content: [.text("hello")]
        )
        let entry: SessionEntry = .message(message)
        let restored = try SessionTestHelpers.roundTrip(entry)
        #expect(restored == entry)
        #expect(restored.id == "msg-1")
        #expect(restored.parent == nil)
    }

    @Test("message entry preserves parent reference on the wire")
    func messageParent() throws {
        let entry: SessionEntry = .message(
            Message(
                id: "child",
                role: .assistant,
                content: [.text("ok")],
                parent: "root"
            )
        )
        let restored = try SessionTestHelpers.roundTrip(entry)
        #expect(restored.parent == "root")
    }

    @Test("model_change round-trips, preserves snake_case wire shape")
    func modelChangeRoundTrip() throws {
        let entry: SessionEntry = .modelChange(
            id: "mc-1",
            parent: "msg-2",
            model: "claude-sonnet-4-6"
        )
        let restored = try SessionTestHelpers.roundTrip(entry)
        #expect(restored == entry)
        // Inspect the on-the-wire JSON to confirm `type` discriminator.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(raw.contains("\"type\":\"model_change\""))
        #expect(raw.contains("\"model\":\"claude-sonnet-4-6\""))
    }

    @Test("compaction round-trips with first_kept_id snake_case key")
    func compactionRoundTrip() throws {
        let entry: SessionEntry = .compaction(
            CompactionEntry(
                id: "cmp-1",
                parent: "msg-5",
                summary: "earlier turns about Swift errors",
                firstKeptId: "msg-6"
            )
        )
        let restored = try SessionTestHelpers.roundTrip(entry)
        #expect(restored == entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(raw.contains("\"first_kept_id\":\"msg-6\""))
    }

    @Test("unknown entry type fails to decode")
    func unknownEntryType() {
        let raw = #"{"type":"banana"}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SessionEntry.self, from: raw)
        }
    }
}

@Suite("JSONLReader / JSONLWriter")
struct JSONLIOTests {
    private var headerEntry: SessionEntry {
        .session(SessionHeader(version: 3, cwd: "/work", created: nil))
    }
    private var rootMessage: SessionEntry {
        .message(Message(id: "root", role: .user, content: [.text("hi")]))
    }
    private var assistantReply: SessionEntry {
        .message(
            Message(
                id: "reply",
                role: .assistant,
                content: [.text("hello")],
                parent: "root"
            )
        )
    }

    @Test("encode then decode a multi-entry transcript losslessly")
    func encodeDecodeRoundTrip() throws {
        let entries: [SessionEntry] = [headerEntry, rootMessage, assistantReply]
        let bytes = try JSONLWriter.encode(entries)
        let result = JSONLReader.decode(bytes)
        #expect(result.errors.isEmpty)
        #expect(result.entries == entries)
    }

    @Test("encoded JSONL ends with a trailing newline so appends are easy")
    func encodingEndsWithNewline() throws {
        let bytes = try JSONLWriter.encode([headerEntry])
        #expect(bytes.last == 0x0A)
    }

    @Test("encoded JSONL contains one entry per line")
    func oneEntryPerLine() throws {
        let entries: [SessionEntry] = [headerEntry, rootMessage, assistantReply]
        let bytes = try JSONLWriter.encode(entries)
        let lf = bytes.filter { $0 == 0x0A }.count
        #expect(lf == entries.count)
    }

    @Test("empty input decodes to no entries and no errors")
    func emptyInput() {
        let result = JSONLReader.decode(Data())
        #expect(result.entries.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test("blank lines are skipped, not surfaced as errors")
    func blankLinesAreIgnored() throws {
        let bytes = try JSONLWriter.encode([rootMessage]) + Data("\n\n".utf8)
        let result = JSONLReader.decode(bytes)
        #expect(result.errors.isEmpty)
        #expect(result.entries.count == 1)
    }

    @Test("CRLF terminators are tolerated on read")
    func crlfTerminators() throws {
        let lfBytes = try JSONLWriter.encode([rootMessage])
        // Replace every \n with \r\n.
        let crlf: [UInt8] = Array(lfBytes).flatMap { byte -> [UInt8] in
            byte == 0x0A ? [0x0D, 0x0A] : [byte]
        }
        let result = JSONLReader.decode(Data(crlf))
        #expect(result.errors.isEmpty)
        #expect(result.entries.count == 1)
    }

    @Test("one malformed line is surfaced as an error, others still decode")
    func malformedLineIsRecoverable() throws {
        let prefix = try JSONLWriter.encode([rootMessage])
        var bytes = prefix
        bytes.append(contentsOf: "this is not json\n".utf8)
        bytes.append(try JSONLWriter.encode([assistantReply]))
        let result = JSONLReader.decode(bytes)
        #expect(result.entries.count == 2)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.line == 2)
    }

    @Test("trailing partial line (no terminator) still decodes")
    func trailingPartialLine() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(rootMessage)
        let result = JSONLReader.decode(line)
        #expect(result.errors.isEmpty)
        #expect(result.entries.count == 1)
    }
}

@Suite("SessionTree")
struct SessionTreeTests {
    // Linear conversation: root → reply
    private let root: SessionEntry = .message(
        Message(id: "root", role: .user, content: [.text("hi")])
    )
    private let reply: SessionEntry = .message(
        Message(
            id: "reply",
            role: .assistant,
            content: [.text("hello")],
            parent: "root"
        )
    )
    private let header: SessionEntry = .session(SessionHeader(version: 3))

    // Branching: root has two child replies, only one of which has a follow-up.
    private var branched: [SessionEntry] {
        [
            header,
            root,
            reply,
            .message(
                Message(
                    id: "reply-alt",
                    role: .assistant,
                    content: [.text("alt hello")],
                    parent: "root"
                )
            ),
            .message(
                Message(
                    id: "follow",
                    role: .user,
                    content: [.text("more please")],
                    parent: "reply"
                )
            ),
        ]
    }

    @Test("walkToTip returns root-to-tip in order")
    func walkToTipLinear() throws {
        let path = try SessionTree.walkToTip(
            entries: [header, root, reply],
            tipID: "reply"
        )
        #expect(path.count == 2)
        #expect(path.first?.id == "root")
        #expect(path.last?.id == "reply")
    }

    @Test("walkToTip on a deeper path includes the intermediate turn")
    func walkToTipDeeper() throws {
        let path = try SessionTree.walkToTip(
            entries: branched,
            tipID: "follow"
        )
        let ids = path.compactMap(\.id)
        #expect(ids == ["root", "reply", "follow"])
    }

    @Test("walkToTip throws for an unknown tip id")
    func walkToTipUnknown() {
        #expect(throws: SwiftPiError.self) {
            _ = try SessionTree.walkToTip(
                entries: [header, root, reply],
                tipID: "missing"
            )
        }
    }

    @Test("walkToTip throws for a broken parent reference")
    func walkToTipBrokenParent() {
        let orphan: SessionEntry = .message(
            Message(
                id: "orphan",
                role: .assistant,
                content: [.text("?")],
                parent: "phantom"
            )
        )
        #expect(throws: SwiftPiError.self) {
            _ = try SessionTree.walkToTip(
                entries: [orphan],
                tipID: "orphan"
            )
        }
    }

    @Test("tipsForBranch returns every leaf in append order")
    func tipsForBranchOrder() {
        let tips = SessionTree.tipsForBranch(entries: branched)
        #expect(tips == ["reply-alt", "follow"])
    }

    @Test("lastTip returns the most recent leaf")
    func lastTipMostRecent() {
        #expect(SessionTree.lastTip(entries: branched) == "follow")
    }

    @Test("lastTip on a header-only entry list returns nil")
    func lastTipHeaderOnly() {
        #expect(SessionTree.lastTip(entries: [header]) == nil)
    }

    @Test("messages(on:) filters out non-message entries")
    func messagesFilter() throws {
        let path = try SessionTree.walkToTip(
            entries: [
                header,
                root,
                .modelChange(id: "mc", parent: "root", model: "claude-sonnet-4-6"),
                reply,
            ],
            tipID: "reply"
        )
        let messages = SessionTree.messages(on: path)
        #expect(messages.count == 2)
        #expect(messages.first?.id == "root")
        #expect(messages.last?.id == "reply")
    }
}
