// ToolTruncation — head+tail truncation matching upstream pi_agent's
// algorithm.
//
// Defaults match the upstream's stated limits so a session's tool
// output budget is the same regardless of which implementation
// produced it:
//
//   - MAX_LINES = 2000   (1000 head + 1000 tail)
//   - MAX_BYTES = 1 MiB
//
// We do NOT enforce GREP_MAX_LINE_LENGTH here because Phase 4 does not
// ship a `grep` tool. When `grep` lands in a later phase it can use
// the same `Limits` type with a tighter `maxBytesPerLine`.

import Foundation
import SwiftPiCore

public enum ToolTruncation {
    public struct Limits: Sendable, Equatable {
        public var maxLines: Int
        public var maxBytes: Int

        public init(maxLines: Int = 2000, maxBytes: Int = 1 * 1024 * 1024) {
            self.maxLines = maxLines
            self.maxBytes = maxBytes
        }

        /// Convenience default matching upstream pi_agent caps.
        public static let `default` = Limits()
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        public var truncated: Bool
        public var originalLineCount: Int
        public var originalByteCount: Int

        public init(
            text: String,
            truncated: Bool,
            originalLineCount: Int,
            originalByteCount: Int
        ) {
            self.text = text
            self.truncated = truncated
            self.originalLineCount = originalLineCount
            self.originalByteCount = originalByteCount
        }
    }

    /// Apply head+tail truncation to `text` per `limits`.
    ///
    /// Algorithm:
    ///   1. Split into lines on `\n`. Count.
    ///   2. If `lineCount > maxLines`: keep `maxLines/2` head and
    ///      `maxLines/2` tail, with a marker between.
    ///   3. If resulting byte count still exceeds `maxBytes`: trim
    ///      tail-side characters until it fits and append a byte
    ///      truncation marker.
    public static func apply(
        _ text: String,
        limits: Limits = .default
    ) -> Result {
        let originalLineCount = countLines(text)
        let originalByteCount = text.utf8.count
        var truncated = false
        var work = text

        if originalLineCount > limits.maxLines {
            work = applyLineLimit(text, maxLines: limits.maxLines)
            truncated = true
        }

        if work.utf8.count > limits.maxBytes {
            work = applyByteLimit(work, maxBytes: limits.maxBytes)
            truncated = true
        }

        return Result(
            text: work,
            truncated: truncated,
            originalLineCount: originalLineCount,
            originalByteCount: originalByteCount
        )
    }

    // MARK: - Internals

    private static func countLines(_ text: String) -> Int {
        // A document is one line minimum if non-empty; every `\n`
        // adds an additional line break.
        guard !text.isEmpty else { return 0 }
        let nl = text.utf8.filter { $0 == 0x0A }.count
        // If the text ends with `\n`, that trailing newline does NOT
        // start a new line — `"a\nb\n"` is two lines, not three.
        let trailing = text.utf8.last == 0x0A ? 1 : 0
        return nl + (1 - trailing)
    }

    private static func applyLineLimit(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let half = maxLines / 2
        let head = lines.prefix(half)
        let tail = lines.suffix(half)
        let omitted = lines.count - head.count - tail.count
        var rebuilt = head.joined(separator: "\n")
        rebuilt += "\n... [\(omitted) lines truncated] ...\n"
        rebuilt += tail.joined(separator: "\n")
        return rebuilt
    }

    private static func applyByteLimit(_ text: String, maxBytes: Int) -> String {
        let marker = "\n... [output truncated: byte limit] ..."
        let markerBytes = marker.utf8.count
        guard maxBytes > markerBytes else {
            // Caller asked for an impossibly small budget; emit the
            // marker on its own, which is still useful diagnostic.
            return marker
        }
        let budget = maxBytes - markerBytes
        // Walk Unicode scalars rather than bytes to avoid splitting a
        // codepoint in the middle.
        var byteAccumulator = 0
        var endIndex = text.startIndex
        for scalar in text.unicodeScalars {
            let next = byteAccumulator + scalar.utf8Count
            if next > budget { break }
            byteAccumulator = next
            endIndex = text.unicodeScalars.index(after: endIndex)
        }
        return String(text[..<endIndex]) + marker
    }
}

private extension Unicode.Scalar {
    /// Number of UTF-8 bytes this scalar occupies.
    var utf8Count: Int {
        switch self.value {
        case 0x0000...0x007F: return 1
        case 0x0080...0x07FF: return 2
        case 0x0800...0xFFFF: return 3
        default: return 4
        }
    }
}
