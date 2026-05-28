// WriteFileTool — create or overwrite a UTF-8 file on disk.
//
// Input schema (object):
//   {
//     "path":    string (required),   file path to write
//     "content": string (required),   new file contents (UTF-8)
//   }
//
// Atomic save = write to a sibling tmp file, remove the existing file
// if any, then move the tmp into place. This is the same pattern
// `SessionStore` uses; we re-derive it locally rather than depend on
// SwiftPiSession to keep the tool module narrow.

import Foundation
import SwiftPiCore

public struct WriteFileTool: Tool {
    public init() {}

    public var name: String { "write" }

    public var description: String {
        "Create or overwrite a UTF-8 file on disk. Atomically via temp-then-move."
    }

    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ])
    }

    public func execute(input: JSONValue) async throws -> ToolOutput {
        guard let object = input.objectValue else {
            throw SwiftPiError.io("write: expected an object input")
        }
        guard let path = object["path"]?.stringValue else {
            throw SwiftPiError.io("write: missing required string `path`")
        }
        guard let content = object["content"]?.stringValue else {
            throw SwiftPiError.io("write: missing required string `content`")
        }

        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SwiftPiError.io(
                "write: could not create parent directory at \(directory.path): \(error.localizedDescription)"
            )
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = directory.appendingPathComponent(
            "\(url.lastPathComponent).tmp-\(pid)-\(UUID().uuidString)"
        )

        let data = Data(content.utf8)
        // Wrap the three filesystem steps in `FilesystemRetry` to
        // absorb the transient permission-denied returns that Windows
        // AV scanners produce under parallel-test contention.
        try FilesystemRetry.run(operation: "write: tmp write at \(tmp.path)") {
            try data.write(to: tmp, options: .atomic)
        }

        let existed = fm.fileExists(atPath: url.path)
        if existed {
            do {
                try FilesystemRetry.run(operation: "write: could not replace existing file at \(url.path)") {
                    try fm.removeItem(at: url)
                }
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
        do {
            try FilesystemRetry.run(operation: "write: move into place at \(url.path)") {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        return ToolOutput(
            content: "Wrote \(data.count) bytes to \(url.path)",
            metadata: [
                "path": .string(url.path),
                "byte_count": .int(data.count),
                "created": .bool(!existed),
            ]
        )
    }
}
