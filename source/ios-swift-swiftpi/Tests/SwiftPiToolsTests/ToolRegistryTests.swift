
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiTools

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("default builtins exposes the five Phase 5 tools in sorted order")
    func defaultBuiltinNames() {
        let registry = ToolRegistry.defaultBuiltins()
        let names = registry.allTools.map(\.name)
        #expect(names == ["bash", "edit", "ls", "read", "write"])
    }

    @Test("tool(named:) returns matching tool, nil for unknown")
    func lookupByName() {
        let registry = ToolRegistry.defaultBuiltins()
        #expect(registry.tool(named: "read")?.name == "read")
        #expect(registry.tool(named: "nope") == nil)
    }

    @Test("execute throws for unknown tool name")
    func unknownToolThrows() async {
        let registry = ToolRegistry.defaultBuiltins()
        do {
            _ = try await registry.execute("nope", input: .object([:]))
            Issue.record("Expected throw for unknown tool")
        } catch {
            // expected
        }
    }

    @Test("duplicate tool name throws at construction")
    func duplicateNameThrows() {
        do {
            _ = try ToolRegistry(tools: [ReadFileTool(), ReadFileTool()])
            Issue.record("Expected throw for duplicate tool name")
        } catch {
            // expected
        }
    }

    @Test("toolDefs has one entry per tool with matching metadata")
    func toolDefsMatchTools() {
        let registry = ToolRegistry.defaultBuiltins()
        let defs = registry.toolDefs
        let tools = registry.allTools
        #expect(defs.count == tools.count)
        for (def, tool) in zip(defs, tools) {
            #expect(def.name == tool.name)
            #expect(def.description == tool.description)
        }
    }

    @Test("end-to-end: write through registry then read it back")
    func writeThenRead() async throws {
        let registry = ToolRegistry.defaultBuiltins()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpi-registry-test")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("hello.txt")
        _ = try await registry.execute(
            "write",
            input: .object([
                "path": .string(target.path),
                "content": .string("hi from registry"),
            ])
        )
        let read = try await registry.execute(
            "read",
            input: .object(["path": .string(target.path)])
        )
        #expect(read.content == "hi from registry")
    }
}
