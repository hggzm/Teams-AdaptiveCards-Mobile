
import Foundation
import Testing
@testable import SwiftPiStreaming

/// Helpers shared across SSE test suites. Wrapped in an enum namespace
/// so the free-function name doesn't collide with Swift Testing's
/// per-suite synthesized members.
enum SSETestHelpers {
    /// Run a string through the splitter as a single chunk and return
    /// the list of lines plus any line dispatched by `finish()`.
    static func split(_ text: String) -> [String] {
        var splitter = SSELineSplitter()
        var lines = splitter.feed(Data(text.utf8))
        lines.append(contentsOf: splitter.finish())
        return lines
    }

    /// Run a sequence of byte chunks through the splitter, mirroring a
    /// real fragmented network stream.
    static func splitChunks(_ chunks: [[UInt8]]) -> [String] {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for chunk in chunks {
            lines.append(contentsOf: splitter.feed(chunk))
        }
        lines.append(contentsOf: splitter.finish())
        return lines
    }
}

@Suite("SSELineSplitter — terminators")
struct SSELineSplitterTerminatorTests {
    @Test("LF separates two lines")
    func lfSeparator() {
        let lines = SSETestHelpers.split("alpha\nbeta\n")
        #expect(lines == ["alpha", "beta"])
    }

    @Test("CRLF separates two lines")
    func crlfSeparator() {
        let lines = SSETestHelpers.split("alpha\r\nbeta\r\n")
        #expect(lines == ["alpha", "beta"])
    }

    @Test("lone CR separates two lines")
    func loneCRSeparator() {
        let lines = SSETestHelpers.split("alpha\rbeta\r")
        #expect(lines == ["alpha", "beta"])
    }

    @Test("mixed terminators on adjacent lines")
    func mixedTerminators() {
        let lines = SSETestHelpers.split("a\nb\r\nc\rd\n")
        #expect(lines == ["a", "b", "c", "d"])
    }

    @Test("trailing line without terminator is emitted by finish()")
    func trailingLineFinish() {
        let lines = SSETestHelpers.split("alpha\nbeta")
        #expect(lines == ["alpha", "beta"])
    }

    @Test("empty input yields no lines")
    func emptyInput() {
        let lines = SSETestHelpers.split("")
        #expect(lines.isEmpty)
    }

    @Test("blank line between two events is preserved as empty string")
    func blankLine() {
        let lines = SSETestHelpers.split("event: ping\ndata: {}\n\nevent: pong\n")
        #expect(lines == ["event: ping", "data: {}", "", "event: pong"])
    }
}

@Suite("SSELineSplitter — BOM")
struct SSELineSplitterBOMTests {
    @Test("UTF-8 BOM at start of stream is stripped")
    func bomStripped() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body: [UInt8] = Array("alpha\nbeta\n".utf8)
        let lines = SSETestHelpers.splitChunks([bom + body])
        #expect(lines == ["alpha", "beta"])
    }

    @Test("BOM split across two chunks is still stripped")
    func bomAcrossChunks() {
        let lines = SSETestHelpers.splitChunks([
            [0xEF, 0xBB],
            [0xBF] + Array("hello\n".utf8),
        ])
        #expect(lines == ["hello"])
    }

    @Test("mid-stream EF BB BF (zero-width no-break space) is preserved")
    func bomMidStreamPreserved() {
        // After the first line, the byte sequence EF BB BF is just a
        // valid UTF-8 ZWNBSP code point (U+FEFF) and must NOT be stripped.
        let firstLine = Array("alpha\n".utf8)
        let zwnbsp: [UInt8] = [0xEF, 0xBB, 0xBF]
        let rest = Array("beta\n".utf8)
        let lines = SSETestHelpers.splitChunks([firstLine + zwnbsp + rest])
        #expect(lines.count == 2)
        #expect(lines[0] == "alpha")
        #expect(lines[1] == "\u{FEFF}beta")
    }
}

@Suite("SSELineSplitter — chunk boundaries")
struct SSELineSplitterBoundaryTests {
    @Test("LF at start of next chunk after CR is consumed as CRLF")
    func crlfAcrossChunks() {
        // Splits the CRLF pair across the chunk boundary.
        let lines = SSETestHelpers.splitChunks([
            Array("alpha\r".utf8),
            Array("\nbeta\n".utf8),
        ])
        #expect(lines == ["alpha", "beta"])
    }

    @Test("non-LF after CR-at-chunk-end keeps the CR as a lone terminator")
    func loneCRAcrossChunks() {
        let lines = SSETestHelpers.splitChunks([
            Array("alpha\r".utf8),
            Array("beta\n".utf8),
        ])
        #expect(lines == ["alpha", "beta"])
    }

    @Test("partial UTF-8 multibyte sequence is buffered across chunks")
    func partialUTF8AcrossChunks() {
        // U+1F600 (😀) is F0 9F 98 80 in UTF-8. Split it down the middle.
        let lines = SSETestHelpers.splitChunks([
            Array("hi ".utf8) + [0xF0, 0x9F],
            [0x98, 0x80] + Array("!\n".utf8),
        ])
        #expect(lines == ["hi 😀!"])
    }

    @Test("two complete events arriving in three chunks parse cleanly")
    func eventBoundary() {
        let payload = "event: ping\ndata: {}\n\nevent: pong\ndata: {}\n\n"
        let bytes = Array(payload.utf8)
        let mid = bytes.count / 2
        let lines = SSETestHelpers.splitChunks([
            Array(bytes[0..<mid]),
            Array(bytes[mid..<mid + 1]),
            Array(bytes[(mid + 1)...]),
        ])
        #expect(lines.contains("event: ping"))
        #expect(lines.contains("event: pong"))
        #expect(lines.filter { $0.isEmpty }.count == 2)
    }
}
