// ReadFileTool — read a file's UTF-8 contents from disk.
//
// Input schema (object):
//   {
//     "path":   string  (required),   file path to read
//     "offset": integer (optional),   1-based starting line
//     "limit":  integer (optional),   max number of lines to return
//   }
//
// On success returns the requested text. Output is run through
// `ToolTruncation` so huge files don't blow the agent's context.
// Binary files (NUL byte in the head) are refused with a typed error
// — Phase 4 does not decode images; that's a later phase.

import Foundation
import SwiftPiCore

public struct ReadFileTool: Tool {
    public let limits: ToolTruncation.Limits

    public init(limits: ToolTruncation.Limits = .default) {
        self.limits = limits
    }

    public var name: String { "read" }

    public var description: String {
        "Read a UTF-8 file from disk. Supports optional 1-based offset/limit windowing."
    }

    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "offset": .object(["type": .string("integer")]),
                "limit": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    public func execute(input: JSONValue) async throws -> ToolOutput {
        guard let object = input.objectValue else {
            throw SwiftPiError.io("read: expected an object input")
        }
        guard let path = object["path"]?.stringValue else {
            throw SwiftPiError.io("read: missing required string `path`")
        }
        let offset = object["offset"]?.intValue
        let limit = object["limit"]?.intValue

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwiftPiError.io("read: file does not exist at \(url.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SwiftPiError.io(
                "read: failed at \(url.path): \(error.localizedDescription)"
            )
        }
        if isProbablyBinary(data) {
            throw SwiftPiError.io(
                "read: refusing to read binary file at \(url.path) (NUL byte in head)"
            )
        }
        let text = String(decoding: data, as: UTF8.self)

        let windowed = windowLines(text, offset: offset, limit: limit)
        let truncated = ToolTruncation.apply(windowed, limits: limits)

        var metadata: [String: JSONValue] = [
            "path": .string(url.path),
            "byte_count": .int(truncated.originalByteCount),
            "line_count": .int(truncated.originalLineCount),
            "truncated": .bool(truncated.truncated),
        ]
        if let offset { metadata["offset"] = .int(offset) }
        if let limit { metadata["limit"] = .int(limit) }
        return ToolOutput(content: truncated.text, metadata: metadata)
    }

    // MARK: - Internals

    /// Look at the first 4 KiB for a NUL byte as a cheap "is this
    /// binary?" probe. Matches the upstream's read-tool heuristic.
    private func isProbablyBinary(_ data: Data) -> Bool {
        let head = data.prefix(4096)
        return head.contains(0)
    }

    /// Apply the 1-based `offset` and `limit` window to `text`. When
    /// neither is supplied the original text is returned unchanged.
    private func windowLines(_ text: String, offset: Int?, limit: Int?) -> String {
        if offset == nil, limit == nil {
            return text
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (offset ?? 1) - 1)
        let end: Int
        if let limit {
            end = min(lines.count, start + max(0, limit))
        } else {
            end = lines.count
        }
        guard start < end else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }
}
