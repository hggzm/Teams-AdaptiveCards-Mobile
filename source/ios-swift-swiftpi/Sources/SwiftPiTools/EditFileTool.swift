// EditFileTool — surgical exact-string replacement in an existing file.
//
// Input schema (object):
//   {
//     "path": string (required),   file path
//     "old":  string (required),   exact substring to find
//     "new":  string (required),   replacement substring
//   }
//
// Behaviour matches the upstream pi_agent semantics: the edit fails if
// `old` is absent, or if `old` appears more than once (ambiguous —
// caller must include enough surrounding context to make the match
// unique). Successful edits write atomically via tmp + move so a
// torn write cannot leave the file in a partial state.

import Foundation
import SwiftPiCore

public struct EditFileTool: Tool {
    public init() {}

    public var name: String { "edit" }

    public var description: String {
        "Surgical edit: replace a unique exact substring with a new one. Fails on missing or ambiguous matches."
    }

    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "old": .object(["type": .string("string")]),
                "new": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("path"),
                .string("old"),
                .string("new"),
            ]),
        ])
    }

    public func execute(input: JSONValue) async throws -> ToolOutput {
        guard let object = input.objectValue else {
            throw SwiftPiError.io("edit: expected an object input")
        }
        guard let path = object["path"]?.stringValue else {
            throw SwiftPiError.io("edit: missing required string `path`")
        }
        guard let old = object["old"]?.stringValue else {
            throw SwiftPiError.io("edit: missing required string `old`")
        }
        guard let new = object["new"]?.stringValue else {
            throw SwiftPiError.io("edit: missing required string `new`")
        }
        if old.isEmpty {
            throw SwiftPiError.io("edit: `old` must not be the empty string")
        }
        if old == new {
            throw SwiftPiError.io("edit: `old` and `new` are identical; nothing to do")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwiftPiError.io("edit: file does not exist at \(url.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SwiftPiError.io(
                "edit: read failed at \(url.path): \(error.localizedDescription)"
            )
        }
        let original = String(decoding: data, as: UTF8.self)

        let matches = countOccurrences(of: old, in: original)
        if matches == 0 {
            throw SwiftPiError.io(
                "edit: `old` substring not found in \(url.path)"
            )
        }
        if matches > 1 {
            throw SwiftPiError.io(
                "edit: `old` substring is ambiguous (found \(matches) occurrences); include more context"
            )
        }
        let updated = original.replacingOccurrences(of: old, with: new)

        let directory = url.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = directory.appendingPathComponent(
            "\(url.lastPathComponent).tmp-\(pid)-\(UUID().uuidString)"
        )
        let updatedBytes = Data(updated.utf8)
        // Wrap the three filesystem steps in `FilesystemRetry` to
        // absorb transient permission-denied returns on Windows.
        try FilesystemRetry.run(operation: "edit: tmp write at \(tmp.path)") {
            try updatedBytes.write(to: tmp, options: .atomic)
        }
        let fm = FileManager.default
        do {
            try FilesystemRetry.run(operation: "edit: could not replace existing file at \(url.path)") {
                try fm.removeItem(at: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        do {
            try FilesystemRetry.run(operation: "edit: move into place at \(url.path)") {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        return ToolOutput(
            content: "Successfully replaced 1 occurrence in \(url.path)",
            metadata: [
                "path": .string(url.path),
                "old_length": .int(old.utf8.count),
                "new_length": .int(new.utf8.count),
                "original_byte_count": .int(data.count),
                "updated_byte_count": .int(updatedBytes.count),
            ]
        )
    }

    // MARK: - Internals

    /// Count non-overlapping occurrences of `needle` in `haystack`.
    /// We use a manual `range(of:range:)` loop rather than
    /// `components(separatedBy:)` so that the empty-string guard at
    /// the entry point doesn't have to do extra work.
    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
