
import Foundation
import Testing
@testable import SwiftPiCore
@testable import SwiftPiTools

// BashTool tests use simple commands that work in BOTH `cmd.exe /C`
// (Windows default) and `/bin/sh -c` (everywhere else). For the few
// cases that need platform-specific syntax we gate with `#if os(...)`.

@Suite("BashTool — basic")
struct BashToolBasicTests {
    @Test("happy path: echo writes to stdout, exit code 0")
    func happyPath() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            input: .object(["command": .string("echo hello swiftpi")])
        )
        #expect(result.content.contains("hello swiftpi"))
        #expect(result.metadata["exit_code"]?.intValue == 0)
        #expect(result.metadata["timed_out"]?.boolValue == false)
        #expect(result.isError == false)
    }

    @Test("non-zero exit code propagates as isError")
    func nonZeroExitCode() async throws {
        let tool = BashTool()
        // Both cmd.exe and /bin/sh accept `exit N`.
        let result = try await tool.execute(
            input: .object(["command": .string("exit 7")])
        )
        #expect(result.metadata["exit_code"]?.intValue == 7)
        #expect(result.isError == true)
        #expect(result.metadata["timed_out"]?.boolValue == false)
    }

    @Test("returns combined stdout and stderr with stderr divider")
    func combinesStdoutAndStderr() async throws {
        let tool = BashTool()
        #if os(Windows)
        // cmd.exe: `echo TARGET 1>&2` writes to stderr.
        let command = "echo stdout-side && echo stderr-side 1>&2"
        #else
        let command = "echo stdout-side; echo stderr-side 1>&2"
        #endif
        let result = try await tool.execute(
            input: .object(["command": .string(command)])
        )
        #expect(result.content.contains("stdout-side"))
        #expect(result.content.contains("stderr-side"))
        #expect(result.content.contains("--- stderr ---"))
    }

    @Test("missing command field throws")
    func missingCommandThrows() async {
        let tool = BashTool()
        do {
            _ = try await tool.execute(input: .object([:]))
            Issue.record("Expected throw for missing command")
        } catch {
            // expected
        }
    }
}

@Suite("BashTool — timeout")
struct BashToolTimeoutTests {
    @Test("command that exceeds timeout returns timed_out result")
    func timeoutFires() async throws {
        let tool = BashTool(defaultTimeoutSeconds: 0.5)
        #if os(Windows)
        // Tight CPU loop entirely inside cmd.exe — no child processes
        // to keep the stdout/stderr pipes open after we terminate().
        // `for /L %i in (1,0,99999) do @rem` iterates 99999 times
        // (step 0 keeps it from terminating naturally for ages).
        let command = "for /L %i in (1,0,99999) do @rem"
        #else
        let command = "while :; do :; done"
        #endif
        let started = Date()
        let result = try await tool.execute(
            input: .object(["command": .string(command)])
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.metadata["timed_out"]?.boolValue == true)
        #expect(result.isError == true)
        // Sanity: the timeout fired well before the (effectively
        // unbounded) command would have completed on its own.
        #expect(elapsed < 3.0, "BashTool timeout took \(elapsed)s — should fire near 0.5s")
    }

    @Test("command that completes well under the timeout reports timed_out=false")
    func underTimeoutNotMarked() async throws {
        let tool = BashTool(defaultTimeoutSeconds: 10)
        let result = try await tool.execute(
            input: .object(["command": .string("echo quick")])
        )
        #expect(result.metadata["timed_out"]?.boolValue == false)
        #expect(result.metadata["exit_code"]?.intValue == 0)
    }
}

@Suite("BashTool — truncation")
struct BashToolTruncationTests {
    @Test("large output is truncated per Tool truncation defaults")
    func largeOutputTruncated() async throws {
        // 500 lines of output — comfortably over a 100-line cap but
        // well under cmd.exe's slowness ceiling. The for-loop syntax
        // differs between cmd.exe and /bin/sh, so we conditionalize.
        #if os(Windows)
        let command = "for /L %i in (1,1,500) do @echo L%i"
        #else
        let command = "for i in $(seq 1 500); do echo L$i; done"
        #endif
        let tool = BashTool(
            defaultTimeoutSeconds: 30,
            limits: ToolTruncation.Limits(maxLines: 100, maxBytes: 1 * 1024 * 1024)
        )
        let result = try await tool.execute(
            input: .object(["command": .string(command)])
        )
        #expect(result.metadata["truncated"]?.boolValue == true)
        // First and last expected lines remain visible.
        // (Tolerate CRLF on Windows.)
        #expect(result.content.contains("L1\n") || result.content.contains("L1\r"))
        #expect(result.content.contains("L500"))
        #expect(result.content.contains("lines truncated"))
    }
}

@Suite("BashTool — registry dispatch")
struct BashToolRegistryDispatchTests {
    @Test("ToolRegistry.defaultBuiltins() dispatches bash end-to-end")
    func registryDispatch() async throws {
        let registry = ToolRegistry.defaultBuiltins()
        let result = try await registry.execute(
            "bash",
            input: .object(["command": .string("echo registry-dispatch")])
        )
        #expect(result.content.contains("registry-dispatch"))
        #expect(result.metadata["exit_code"]?.intValue == 0)
    }

    @Test("BashTool's toolDef carries the bash name and snake_case schema")
    func toolDefShape() {
        let def = BashTool().toolDef
        #expect(def.name == "bash")
        #expect(def.description.lowercased().contains("shell"))
        // input_schema must mention `command` somewhere in its object structure.
        let raw = String(
            decoding: (try? JSONEncoder().encode(def)) ?? Data(),
            as: UTF8.self
        )
        #expect(raw.contains("input_schema"))
        #expect(raw.contains("command"))
    }
}
