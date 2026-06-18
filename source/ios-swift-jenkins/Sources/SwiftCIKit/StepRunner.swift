import Foundation

/// Runs one pipeline step as a child process and captures combined
/// stdout/stderr.
///
/// On Windows, steps run via `cmd.exe /c <run>`; on POSIX via
/// `/bin/sh -c <run>`. The blocking `Process` work is dispatched to a
/// detached task so the calling actor (typically `BuildExecutor`) is
/// not held by the synchronous `waitUntilExit()` call.
///
/// Per `~/.claude/memories/swift-foundation-process-linux.md`, we do
/// NOT use `terminationHandler` here — the synchronous `waitUntilExit()`
/// + read-to-end pattern is the only path that's reliable across all
/// three swiftci platforms.
public struct StepRunner: Sendable {
    public init() {}

    public struct Result: Sendable, Equatable {
        public let exitCode: Int32
        public let output: String
    }

    /// Run one `step`.
    ///
    /// - `workingDirectory`: if provided, becomes the child's CWD;
    ///   otherwise the child inherits the parent's CWD.
    /// - `environment`: additional env vars layered on top of the
    ///   inherited parent environment. Later keys override earlier
    ///   ones, so callers can confidently inject `SWIFTCI_*` values
    ///   without worrying about what the host already exposes.
    /// - `processLatch`: optional `ProcessLatch` that receives the
    ///   running `Foundation.Process` immediately after `process.run()`
    ///   succeeds. The executor uses this to terminate the child when
    ///   a build is canceled mid-step. The latch is cleared (set to
    ///   `nil`) before this method returns so a stale handle can't
    ///   leak past the step.
    public func run(
        _ step: Pipeline.Step,
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        processLatch: ProcessLatch? = nil
    ) async throws -> Result {
        let command = step.run
        let wd = workingDirectory
        // Merge: parent env first, then step env, then per-call extras
        // last (so the executor's SWIFTCI_* keys always win).
        var env = ProcessInfo.processInfo.environment
        for (k, v) in step.env { env[k] = v }
        for (k, v) in environment { env[k] = v }
        let mergedEnv = env
        let latch = processLatch
        return try await Task.detached(priority: .userInitiated) { () throws -> Result in
            let process = Foundation.Process()
            let pipe = Pipe()
            #if os(Windows)
            let comspec = mergedEnv["ComSpec"]
                ?? "C:\\Windows\\System32\\cmd.exe"
            process.executableURL = URL(fileURLWithPath: comspec)
            process.arguments = ["/c", command]
            #else
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            #endif
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = mergedEnv
            if let wd { process.currentDirectoryURL = wd }
            try process.run()
            if let latch {
                await latch.setProcess(process)
            }
            process.waitUntilExit()
            if let latch {
                await latch.clear()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
                ?? "(\(data.count) bytes of non-UTF-8 output)"
            return Result(exitCode: process.terminationStatus, output: output)
        }.value
    }
}

/// One-step process latch shared between the executor and the
/// `Task.detached` body inside `StepRunner.run`. The executor holds a
/// reference, `StepRunner` populates it after `process.run()`. To
/// cancel a running step, the executor calls `terminate()` from any
/// isolation domain.
///
/// `Foundation.Process` itself is not `Sendable`; isolating it inside
/// this actor gives us a Sendable handle without crossing actor
/// boundaries with the raw `Process`.
///
/// Pending-terminate semantics: if `terminate()` is called BEFORE
/// `setProcess(_:)`, the latch records the request and applies it
/// immediately when the process IS set. This handles the race where
/// the executor cancels mid-step before `StepRunner` has actually
/// launched the child.
public actor ProcessLatch {
    private var process: Foundation.Process?
    private var pendingTerminate: Bool = false

    public init() {}

    func setProcess(_ p: Foundation.Process) {
        self.process = p
        if pendingTerminate {
            pendingTerminate = false
            if p.isRunning {
                #if os(Windows)
                killProcessTree(pid: p.processIdentifier)
                #endif
                p.terminate()
            }
        }
    }

    func clear() {
        self.process = nil
        self.pendingTerminate = false
    }

    /// Terminate the running process if one is present. If the latch
    /// has not yet received a process, the request is recorded and
    /// honored as soon as one is registered (via `setProcess(_:)`).
    /// On macOS/Linux this sends SIGTERM; on Windows it shells out to
    /// `taskkill /T /F` to kill the whole process tree before calling
    /// `Foundation.Process.terminate()`. The tree-kill is required
    /// because every step runs inside `cmd.exe /c <run>`, so simply
    /// terminating cmd leaves grandchildren (PowerShell, ping,
    /// long-running tools) orphaned. Worse, an orphaned grandchild
    /// still holds the inherited stdout/stderr pipe handle open, so
    /// `Pipe.fileHandleForReading.readDataToEndOfFile()` inside
    /// `StepRunner.run` blocks indefinitely waiting for EOF on a
    /// writer that's still very much alive. Tree-killing breaks the
    /// pipe immediately and lets the build wind down promptly.
    public func terminate() {
        if let p = process {
            if p.isRunning {
                #if os(Windows)
                killProcessTree(pid: p.processIdentifier)
                #endif
                p.terminate()
            }
        } else {
            pendingTerminate = true
        }
    }

    #if os(Windows)
    /// Tree-kill `pid` and every descendant using `taskkill`. Best-
    /// effort: failures are swallowed because the subsequent
    /// `Foundation.Process.terminate()` still has to run regardless.
    /// We don't wait for taskkill to finish — it's typically faster
    /// than `terminate()` on its own, but waiting would hold up the
    /// actor for ~100 ms per cancel and isn't necessary for
    /// correctness (terminate is itself best-effort).
    private nonisolated func killProcessTree(pid: Int32) {
        guard pid > 0 else { return }
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath:
            "C:\\Windows\\System32\\taskkill.exe")
        task.arguments = ["/T", "/F", "/PID", String(pid)]
        // Detach stdio so the killed processes' pipes don't leak into
        // taskkill's own stdout.
        task.standardOutput = nil
        task.standardError = nil
        task.standardInput = nil
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Best-effort; fall through to `process.terminate()`.
        }
    }
    #endif

    /// True when a process is currently registered (used by tests).
    public var hasProcess: Bool { process != nil }
}
