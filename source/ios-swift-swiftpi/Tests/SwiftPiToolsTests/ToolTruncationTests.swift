
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiTools

@Suite("ToolTruncation")
struct ToolTruncationTests {
    @Test("short text passes through unchanged")
    func shortTextUnchanged() {
        let text = "hello\nworld\n"
        let result = ToolTruncation.apply(text)
        #expect(result.text == text)
        #expect(!result.truncated)
        #expect(result.originalLineCount == 2)
        #expect(result.originalByteCount == text.utf8.count)
    }

    @Test("line limit yields head + marker + tail")
    func lineLimitHeadTail() {
        let lineCount = 20
        let limit = ToolTruncation.Limits(maxLines: 6, maxBytes: 10 * 1024)
        var lines: [String] = []
        for i in 1...lineCount { lines.append("L\(i)") }
        let text = lines.joined(separator: "\n")
        let result = ToolTruncation.apply(text, limits: limit)
        #expect(result.truncated)
        #expect(result.text.contains("L1"))
        #expect(result.text.contains("L20"))
        #expect(result.text.contains("[14 lines truncated]"))
        // Should NOT contain a mid-range line.
        #expect(!result.text.contains("L10"))
    }

    @Test("byte limit appends byte-truncation marker")
    func byteLimit() {
        // Use a line budget so generous it never trips, leaving the
        // byte budget to be the constraint.
        let limits = ToolTruncation.Limits(maxLines: 1_000_000, maxBytes: 64)
        let text = String(repeating: "abcdefghij", count: 50)  // 500 bytes
        let result = ToolTruncation.apply(text, limits: limits)
        #expect(result.truncated)
        #expect(result.text.utf8.count <= 64)
        #expect(result.text.contains("byte limit"))
    }

    @Test("multi-byte UTF-8 not split by byte limit")
    func byteLimitNoSplitMultibyte() {
        // 😀 = F0 9F 98 80 (4 bytes). 16 emoji = 64 bytes; budget
        // exactly that size MINUS the marker should keep some emoji.
        let limits = ToolTruncation.Limits(
            maxLines: 1_000_000,
            maxBytes: 80
        )
        let text = String(repeating: "😀", count: 100)
        let result = ToolTruncation.apply(text, limits: limits)
        #expect(result.truncated)
        // The result must remain valid UTF-8 (decoding round-trips).
        let bytes = Data(result.text.utf8)
        let restored = String(decoding: bytes, as: UTF8.self)
        #expect(restored == result.text)
    }

    @Test("empty text reports zero lines")
    func emptyText() {
        let result = ToolTruncation.apply("")
        #expect(result.text.isEmpty)
        #expect(!result.truncated)
        #expect(result.originalLineCount == 0)
        #expect(result.originalByteCount == 0)
    }
}
