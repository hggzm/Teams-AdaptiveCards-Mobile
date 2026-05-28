// ListDirectoryTool — list directory contents, alphabetically sorted.
//
// Input schema (object):
//   {
//     "path":  string  (required),   directory to list
//     "limit": integer (optional),   max entries to return
//   }
//
// Output: one entry per line. Directories carry a trailing `/`. The
// list is alphabetically sorted (locale-insensitive `<` on Swift
// String values) for determinism. Hidden entries (leading dot) are
// included; the LLM can ask for a filtered view in subsequent turns.

import Foundation
import SwiftPiCore

public struct ListDirectoryTool: Tool {
    public let defaultLimit: Int

    public init(defaultLimit: Int = 500) {
        self.defaultLimit = defaultLimit
    }

    public var name: String { "ls" }

    public var description: String {
        "List directory contents alphabetically. Directories are marked with a trailing slash."
    }

    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    public func execute(input: JSONValue) async throws -> ToolOutput {
        guard let object = input.objectValue else {
            throw SwiftPiError.io("ls: expected an object input")
        }
        guard let path = object["path"]?.stringValue else {
            throw SwiftPiError.io("ls: missing required string `path`")
        }
        let limit = object["limit"]?.intValue ?? defaultLimit

        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else {
            throw SwiftPiError.io("ls: directory does not exist at \(url.path)")
        }
        guard isDir.boolValue else {
            throw SwiftPiError.io("ls: path is not a directory: \(url.path)")
        }

        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            throw SwiftPiError.io(
                "ls: read failed at \(url.path): \(error.localizedDescription)"
            )
        }

        var formatted: [String] = []
        formatted.reserveCapacity(children.count)
        for child in children {
            let name = child.lastPathComponent
            var childIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
            formatted.append(childIsDir.boolValue ? "\(name)/" : name)
        }
        formatted.sort()
        let totalCount = formatted.count
        let truncated = formatted.count > limit
        if truncated {
            formatted = Array(formatted.prefix(limit))
        }
        let body = formatted.joined(separator: "\n")
        return ToolOutput(
            content: body,
            metadata: [
                "path": .string(url.path),
                "entry_count": .int(totalCount),
                "returned": .int(formatted.count),
                "truncated": .bool(truncated),
            ]
        )
    }
}
