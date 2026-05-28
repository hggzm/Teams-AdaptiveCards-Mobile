
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiTools

/// Shared filesystem scaffolding for the tool tests. Each test creates
/// a unique directory under the system temp dir and cleans up after
/// itself regardless of how it exits.
private struct TempToolDir {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpi-tools-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        self.url = base
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("ReadFileTool")
struct ReadFileToolTests {
    @Test("reads UTF-8 content and reports metadata")
    func readsBasicFile() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("hello.txt")
        let text = "Hello, swiftpi.\nLine two.\n"
        try text.data(using: .utf8)!.write(to: target)
        let tool = ReadFileTool()
        let result = try await tool.execute(
            input: .object(["path": .string(target.path)])
        )
        #expect(result.content.contains("Hello, swiftpi."))
        #expect(result.metadata["byte_count"]?.intValue == text.utf8.count)
        #expect(result.metadata["line_count"]?.intValue == 2)
        #expect(result.metadata["truncated"]?.boolValue == false)
    }

    @Test("offset and limit window lines")
    func readsLineWindow() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("multi.txt")
        let lines = (1...10).map { "L\($0)" }.joined(separator: "\n")
        try lines.data(using: .utf8)!.write(to: target)
        let tool = ReadFileTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(target.path),
                "offset": .int(3),
                "limit": .int(2),
            ])
        )
        #expect(result.content == "L3\nL4")
    }

    @Test("missing required path throws")
    func missingPathThrows() async {
        let tool = ReadFileTool()
        do {
            _ = try await tool.execute(input: .object([:]))
            Issue.record("Expected throw for missing `path`")
        } catch {
            // expected
        }
    }

    @Test("non-existent file throws")
    func nonExistentFileThrows() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let tool = ReadFileTool()
        do {
            _ = try await tool.execute(
                input: .object(["path": .string(tmp.file("nope.txt").path)])
            )
            Issue.record("Expected throw for missing file")
        } catch {
            // expected
        }
    }

    @Test("binary file (NUL in head) is refused")
    func binaryFileRefused() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("binary.bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])
            .write(to: target)
        let tool = ReadFileTool()
        do {
            _ = try await tool.execute(
                input: .object(["path": .string(target.path)])
            )
            Issue.record("Expected throw for binary file")
        } catch {
            // expected
        }
    }
}

@Suite("WriteFileTool")
struct WriteFileToolTests {
    @Test("creates a new file and reports metadata")
    func createsNewFile() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("new.txt")
        let tool = WriteFileTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(target.path),
                "content": .string("hello"),
            ])
        )
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written == "hello")
        #expect(result.metadata["created"]?.boolValue == true)
        #expect(result.metadata["byte_count"]?.intValue == 5)
    }

    @Test("overwrites an existing file")
    func overwritesExisting() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("existing.txt")
        try "before".data(using: .utf8)!.write(to: target)
        let tool = WriteFileTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(target.path),
                "content": .string("after"),
            ])
        )
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written == "after")
        #expect(result.metadata["created"]?.boolValue == false)
    }

    @Test("creates intermediate directories")
    func createsIntermediateDirs() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let nested = tmp.url
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("deep.txt")
        let tool = WriteFileTool()
        _ = try await tool.execute(
            input: .object([
                "path": .string(nested.path),
                "content": .string("ok"),
            ])
        )
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("leaves no .tmp- siblings on success")
    func noTempSiblings() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("clean.txt")
        let tool = WriteFileTool()
        _ = try await tool.execute(
            input: .object([
                "path": .string(target.path),
                "content": .string("ok"),
            ])
        )
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        let tmps = siblings.filter { $0.contains(".tmp-") }
        #expect(tmps.isEmpty)
    }
}

@Suite("EditFileTool")
struct EditFileToolTests {
    @Test("replaces a unique occurrence")
    func uniqueReplacement() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("source.swift")
        try "func foo() {}\n".data(using: .utf8)!.write(to: target)
        let tool = EditFileTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(target.path),
                "old": .string("foo"),
                "new": .string("bar"),
            ])
        )
        let updated = try String(contentsOf: target, encoding: .utf8)
        #expect(updated == "func bar() {}\n")
        #expect(result.metadata["old_length"]?.intValue == 3)
        #expect(result.metadata["new_length"]?.intValue == 3)
    }

    @Test("missing old substring throws")
    func missingSubstringThrows() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("noop.txt")
        try "abc".data(using: .utf8)!.write(to: target)
        let tool = EditFileTool()
        do {
            _ = try await tool.execute(
                input: .object([
                    "path": .string(target.path),
                    "old": .string("xyz"),
                    "new": .string("?"),
                ])
            )
            Issue.record("Expected throw for missing substring")
        } catch {
            // expected
        }
    }

    @Test("ambiguous match throws and leaves the file unchanged")
    func ambiguousThrowsAndPreserves() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("ambig.txt")
        let original = "let x = 1\nlet x = 2\n"
        try original.data(using: .utf8)!.write(to: target)
        let tool = EditFileTool()
        do {
            _ = try await tool.execute(
                input: .object([
                    "path": .string(target.path),
                    "old": .string("let x"),
                    "new": .string("var x"),
                ])
            )
            Issue.record("Expected throw on ambiguous match")
        } catch {
            // expected
        }
        let after = try String(contentsOf: target, encoding: .utf8)
        #expect(after == original)
    }

    @Test("empty old string is rejected")
    func emptyOldRejected() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("any.txt")
        try "x".data(using: .utf8)!.write(to: target)
        let tool = EditFileTool()
        do {
            _ = try await tool.execute(
                input: .object([
                    "path": .string(target.path),
                    "old": .string(""),
                    "new": .string("y"),
                ])
            )
            Issue.record("Expected throw on empty `old`")
        } catch {
            // expected
        }
    }

    @Test("identical old and new is rejected")
    func identicalRejected() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("same.txt")
        try "abc".data(using: .utf8)!.write(to: target)
        let tool = EditFileTool()
        do {
            _ = try await tool.execute(
                input: .object([
                    "path": .string(target.path),
                    "old": .string("abc"),
                    "new": .string("abc"),
                ])
            )
            Issue.record("Expected throw on identical old/new")
        } catch {
            // expected
        }
    }
}

@Suite("ListDirectoryTool")
struct ListDirectoryToolTests {
    @Test("lists files and marks directories with trailing slash")
    func basicListing() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let nestedDir = tmp.url.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(
            at: nestedDir,
            withIntermediateDirectories: false
        )
        try "a".data(using: .utf8)!.write(to: tmp.file("alpha.txt"))
        try "b".data(using: .utf8)!.write(to: tmp.file("bravo.txt"))

        let tool = ListDirectoryTool()
        let result = try await tool.execute(
            input: .object(["path": .string(tmp.url.path)])
        )
        let lines = result.content.split(separator: "\n").map { String($0) }
        #expect(lines == ["alpha.txt", "bravo.txt", "subdir/"])
        #expect(result.metadata["entry_count"]?.intValue == 3)
    }

    @Test("limit truncates the list and reports it")
    func limitTruncates() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        for i in 0..<10 {
            try "x".data(using: .utf8)!.write(to: tmp.file("f\(i).txt"))
        }
        let tool = ListDirectoryTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(tmp.url.path),
                "limit": .int(3),
            ])
        )
        let lines = result.content.split(separator: "\n").map { String($0) }
        #expect(lines.count == 3)
        #expect(result.metadata["truncated"]?.boolValue == true)
        #expect(result.metadata["entry_count"]?.intValue == 10)
    }

    @Test("missing path throws")
    func missingPathThrows() async {
        let tool = ListDirectoryTool()
        do {
            _ = try await tool.execute(input: .object([:]))
            Issue.record("Expected throw for missing path")
        } catch {
            // expected
        }
    }

    @Test("path is not a directory throws")
    func notADirectoryThrows() async throws {
        let tmp = try TempToolDir()
        defer { tmp.cleanup() }
        let target = tmp.file("a-file.txt")
        try "x".data(using: .utf8)!.write(to: target)
        let tool = ListDirectoryTool()
        do {
            _ = try await tool.execute(
                input: .object(["path": .string(target.path)])
            )
            Issue.record("Expected throw for file (not dir)")
        } catch {
            // expected
        }
    }
}
