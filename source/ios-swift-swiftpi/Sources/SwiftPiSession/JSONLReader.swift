// JSONLReader — decode a session JSONL file into a list of typed
// `SessionEntry` values.
//
// Behaviour:
//   - LF, CRLF, and lone-CR line terminators are all accepted (mirrors
//     the SSE line splitter — JSONL files written on Windows often
//     pick up CRLF whether we want them to or not).
//   - Empty lines are ignored.
//   - One malformed line does not abort the read; it is surfaced via
//     `JSONLReadResult.errors` and the next line is attempted.
//   - Trailing partial line (no final terminator) is included.

import Foundation
import SwiftPiCore

public struct JSONLReadResult: Sendable, Equatable {
    public var entries: [SessionEntry]
    public var errors: [JSONLDecodeError]

    public init(entries: [SessionEntry] = [], errors: [JSONLDecodeError] = []) {
        self.entries = entries
        self.errors = errors
    }
}

public struct JSONLDecodeError: Sendable, Equatable, Error, CustomStringConvertible {
    /// 1-based line number where the error occurred.
    public let line: Int
    /// Human-readable description of the failure.
    public let reason: String

    public init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }

    public var description: String {
        "JSONL line \(line): \(reason)"
    }
}

public enum JSONLReader {
    /// Decode JSONL `Data` into typed entries plus any per-line errors.
    public static func decode(_ data: Data) -> JSONLReadResult {
        let lines = splitLines(data)
        var result = JSONLReadResult()
        let decoder = JSONDecoder()
        for (lineIndex, line) in lines.enumerated() {
            // Skip empty lines (legal in JSONL but carry no entry).
            let trimmed = line.trimmingTrailingCRsAndSpaces()
            if trimmed.isEmpty { continue }
            do {
                let entry = try decoder.decode(SessionEntry.self, from: Data(trimmed.utf8))
                result.entries.append(entry)
            } catch let error as DecodingError {
                result.errors.append(
                    JSONLDecodeError(
                        line: lineIndex + 1,
                        reason: decodingErrorDescription(error)
                    )
                )
            } catch {
                result.errors.append(
                    JSONLDecodeError(
                        line: lineIndex + 1,
                        reason: String(describing: error)
                    )
                )
            }
        }
        return result
    }

    /// Decode a session file at the given URL. Returns an empty result
    /// when the file does not exist (treat-as-empty semantics: a fresh
    /// session is just an absent file).
    public static func decode(contentsOf url: URL) throws -> JSONLReadResult {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            return JSONLReadResult()
        }
        do {
            let data = try Data(contentsOf: url)
            return decode(data)
        } catch {
            throw SwiftPiError.io(
                "JSONL read failed at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Internals

    /// Split `Data` into UTF-8 lines using LF as the canonical
    /// terminator. Trailing CR characters are stripped by
    /// `trimmingTrailingCRsAndSpaces()` on each line.
    private static func splitLines(_ data: Data) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == 0x0A {  // LF
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                continue
            }
            current.append(byte)
        }
        // Trailing partial line (no final terminator).
        if !current.isEmpty {
            lines.append(String(decoding: current, as: UTF8.self))
        }
        return lines
    }

    private static func decodingErrorDescription(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx),
             .keyNotFound(_, let ctx),
             .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}

private extension String {
    /// Trim a single trailing CR (left over from CRLF terminators
    /// embedded in a Windows-written JSONL file) plus any whitespace
    /// the operator may have hand-typed.
    func trimmingTrailingCRsAndSpaces() -> String {
        var s = self
        while let last = s.last, last == "\r" || last == " " || last == "\t" {
            s.removeLast()
        }
        return s
    }
}
