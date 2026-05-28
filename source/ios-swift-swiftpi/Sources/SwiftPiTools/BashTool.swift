// BashTool — run a shell command with a bounded timeout.
//
// Cross-platform shell selection: on Windows we launch `cmd.exe /C
// <command>`, on every Unix-like host `/bin/sh -c <command>`. The
// tool name stays `bash` for upstream pi_agent compatibility; the
// LLM sees the same `bash` tool regardless of host shell.
//
// Lifecycle invariants (do NOT relax these without re-reading
// /memories/swift-foundation-process-linux.md):
//
//   1. `process.terminationHandler` is assigned BEFORE
//      `process.run()`. On swift-corelibs-foundation a fast child
//      that exits between `run()` and a late handler assignment
//      drops the termination notification on the floor, deadlocking
//      `withCheckedContinuation` indefinitely.
//
//   2. A one-shot `ProcessState` actor latch arbitrates between the
//      termination handler and the timeout `Task`. Whoever calls
//      `markCompleted()` first wins and resumes the continuation;
//      the loser silently drops its result so we never double-resume.
//
// Process-tree cleanup (Unix `posix_kill` walk, Windows JobObject) is
// a known Phase 5+ gap: `Foundation.Process.terminate()` kills only
// the direct child. For v0.1 this is acceptable since the tool's
// main use case is short-lived diagnostic commands; full tree
// cleanup arrives in a later phase.

import Foundation
import SwiftPiCore

public struct BashTool: Tool {
    public let defaultTimeoutSeconds: TimeInterval
    public let limits: ToolTruncation.Limits
    public let shellLauncher: ShellLauncher

    public init(
        defaultTimeoutSeconds: TimeInterval = 120,
        limits: ToolTruncation.Limits = .default,
        shellLauncher: ShellLauncher = .platformDefault
    ) {
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.limits = limits
        self.shellLauncher = shellLauncher
    }

    public var name: String { "bash" }

    public var description: String {
        "Run a shell command with a bounded timeout. Returns combined stdout+stderr."
    }

    public var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string")]),
                "timeout": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("command")]),
        ])
    }

    public func execute(input: JSONValue) async throws -> ToolOutput {
        guard let object = input.objectValue else {
            throw SwiftPiError.io("bash: expected an object input")
        }
        guard let command = object["command"]?.stringValue else {
            throw SwiftPiError.io("bash: missing required string `command`")
        }
        // Honor an explicit override; otherwise the configured default.
        // `timeout: 0` means "no timeout"; we translate that into a
        // very large value so the timeout `Task` simply never wakes
        // before the real process completes.
        let configuredTimeout = object["timeout"]?.doubleValue
            ?? Double(object["timeout"]?.intValue ?? 0)
        let timeout: TimeInterval
        if configuredTimeout > 0 {
            timeout = configuredTimeout
        } else if configuredTimeout == 0 && object["timeout"] != nil {
            // Explicit `timeout: 0` requested. Use a value large enough
            // to be "effectively infinite" without breaking the timeout
            // `Task`'s integer-nanosecond math.
            timeout = TimeInterval(60 * 60 * 24 * 365)  // one year
        } else {
            timeout = defaultTimeoutSeconds
        }

        return try await run(command: command, timeout: timeout)
    }

    // MARK: - Internals

    private func run(command: String, timeout: TimeInterval) async throws -> ToolOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = shellLauncher.executable
        process.arguments = shellLauncher.argumentBuilder(command)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let latch = ProcessState()
        let limits = self.limits

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolOutput, Error>) in
            // Pipes are documented thread-safe for the read APIs we
            // call below; mark them as nonisolated(unsafe) so the
            // sendability check accepts the cross-context captures.
            nonisolated(unsafe) let outPipe = stdoutPipe
            nonisolated(unsafe) let errPipe = stderrPipe
            nonisolated(unsafe) let proc = process

            // Step 1: termination handler — assigned BEFORE run() per
            // /memories/swift-foundation-process-linux.md. The handler
            // races against the timeout. Whichever path wins
            // `latch.markCompleted()` resumes the continuation; the
            // other path silently drops its result.
            proc.terminationHandler = { finishedProc in
                guard latch.markCompleted() else { return }
                let exitCode = finishedProc.terminationStatus
                let output = Self.assembleOutput(
                    stdoutPipe: outPipe,
                    stderrPipe: errPipe,
                    exitCode: exitCode,
                    timedOut: false,
                    limits: limits
                )
                continuation.resume(returning: output)
            }

            // Step 2: run() can throw if the executable isn't found.
            // The handler will never fire in that case — null it out
            // and resume with the error.
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                continuation.resume(throwing: SwiftPiError.io(
                    "bash: spawn failed for \(shellLauncher.executable.path): \(error.localizedDescription)"
                ))
                return
            }

            // Step 3: arm the timeout via GCD `asyncAfter`. GCD has its
            // own thread pool, independent of Swift Concurrency
            // executors and of Foundation's internal Process monitor
            // (which on Windows can lag if the spawned process has
            // long-lived children that keep the pipe handles open).
            //
            // On timeout we win the latch, call terminate(), drain
            // whatever output is buffered (non-blocking via
            // availableData), and resume the continuation directly.
            // The termination handler will still fire when the OS
            // eventually reaps the child tree, but the latch makes
            // that path a no-op.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard latch.markCompleted() else { return }
                if proc.isRunning {
                    proc.terminate()
                }
                let output = Self.assembleOutput(
                    stdoutPipe: outPipe,
                    stderrPipe: errPipe,
                    exitCode: -1,
                    timedOut: true,
                    limits: limits
                )
                continuation.resume(returning: output)
            }
        }
    }

    /// Build the final `ToolOutput` from the captured pipes plus exit
    /// metadata. Static so both completion paths can call it without
    /// borrowing the `self` reference across actor boundaries.
    private static func assembleOutput(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        exitCode: Int32,
        timedOut: Bool,
        limits: ToolTruncation.Limits
    ) -> ToolOutput {
        let stdoutData: Data
        let stderrData: Data
        if timedOut {
            // The process is being killed; only drain what's already
            // buffered to avoid blocking on the read end.
            stdoutData = stdoutPipe.fileHandleForReading.availableData
            stderrData = stderrPipe.fileHandleForReading.availableData
        } else {
            // Process is fully exited; readDataToEndOfFile returns
            // promptly.
            stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd())
                ?? stdoutPipe.fileHandleForReading.availableData
            stderrData = (try? stderrPipe.fileHandleForReading.readToEnd())
                ?? stderrPipe.fileHandleForReading.availableData
        }
        let stdoutText = String(decoding: stdoutData, as: UTF8.self)
        let stderrText = String(decoding: stderrData, as: UTF8.self)

        var combined = stdoutText
        if !stderrText.isEmpty {
            if !combined.isEmpty && !combined.hasSuffix("\n") {
                combined.append("\n")
            }
            combined.append("--- stderr ---\n")
            combined.append(stderrText)
        }
        let truncated = ToolTruncation.apply(combined, limits: limits)

        var metadata: [String: JSONValue] = [
            "exit_code": .int(Int(exitCode)),
            "timed_out": .bool(timedOut),
            "truncated": .bool(truncated.truncated),
            "byte_count": .int(truncated.originalByteCount),
            "line_count": .int(truncated.originalLineCount),
        ]
        metadata["stdout_byte_count"] = .int(stdoutData.count)
        metadata["stderr_byte_count"] = .int(stderrData.count)

        return ToolOutput(
            content: truncated.text,
            metadata: metadata,
            isError: timedOut || exitCode != 0
        )
    }
}

// MARK: - ShellLauncher

/// How to launch a shell command for `BashTool`. Provided as a
/// configurable struct so tests can drop in a deterministic shell
/// (e.g. a thin wrapper script) without subclassing.
public struct ShellLauncher: Sendable {
    public let executable: URL
    public let argumentBuilder: @Sendable (String) -> [String]

    public init(
        executable: URL,
        argumentBuilder: @escaping @Sendable (String) -> [String]
    ) {
        self.executable = executable
        self.argumentBuilder = argumentBuilder
    }

    /// The default platform shell:
    ///   - Windows: `%COMSPEC%` (typically `C:\Windows\System32\cmd.exe`)
    ///     invoked with `/C <command>`.
    ///   - Everything else: `/bin/sh -c <command>`. We deliberately
    ///     use `/bin/sh` rather than `/bin/bash` because `sh` is
    ///     guaranteed present on macOS and most Linux distros while
    ///     bash is not always shipped.
    public static var platformDefault: ShellLauncher {
        #if os(Windows)
        let cmd = ProcessInfo.processInfo.environment["COMSPEC"]
            ?? "C:\\Windows\\System32\\cmd.exe"
        return ShellLauncher(
            executable: URL(fileURLWithPath: cmd),
            argumentBuilder: { ["/C", $0] }
        )
        #else
        return ShellLauncher(
            executable: URL(fileURLWithPath: "/bin/sh"),
            argumentBuilder: { ["-c", $0] }
        )
        #endif
    }
}
