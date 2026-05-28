import Foundation

/// Result of running a shell command.
public struct ShellResult: Codable, Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum ShellError: Error, Sendable, Equatable {
    case launchFailed(String)
    case noShellAvailable
}

/// Internal latch coordinating `terminationHandler` resumption with an
/// optional timeout race. Resumes the underlying continuation exactly
/// once. Required because swift-corelibs-foundation on Linux loses the
/// termination notification if the handler is assigned after the
/// process has already exited; see
/// memories/swift-foundation-process-linux.md.
fileprivate actor ProcessLatch {
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ cont: CheckedContinuation<Void, Never>) {
        self.continuation = cont
    }

    func fire() {
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

/// Runs shell commands on the host. Cross-platform: uses `cmd /c` on
/// Windows and `/bin/sh -c` everywhere else. Output is buffered in
/// memory; intended for short, bounded commands invoked by agents.
///
/// `terminationHandler` is **assigned before** `process.run()`, and a
/// one-shot `ProcessLatch` arbitrates between handler-fire and
/// timeout-fire so the underlying continuation resumes exactly once.
public actor LocalShellExecutor {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// Run a single shell command and capture its output.
    public func execute(_ command: String) async throws -> ShellResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", command]
        #else
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        #endif

        let latch = ProcessLatch()

        // Read pipes eagerly so the child doesn't block on a full
        // pipe buffer for either stream.
        let stdoutTask = Task.detached { () -> Data in
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached { () -> Data in
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await latch.arm(cont) }
            process.terminationHandler = { _ in
                Task { await latch.fire() }
            }

            do {
                try process.run()
            } catch {
                // Launch failed; surface via the latch and a sentinel.
                Task { await latch.fire() }
            }
        }

        // Wait for either real termination or the timeout race.
        let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                while process.isRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return false
            }
            group.addTask { [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    return true
                }
                return false
            }
            var result = false
            for await did in group {
                if did { result = true }
            }
            return result
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

// MARK: - ShellTool

public struct ShellInput: Codable, Sendable, Hashable {
    public var command: String
    public init(command: String) { self.command = command }
}

/// Bridges `LocalShellExecutor` into the `Tool` protocol so an agent
/// can invoke shell commands through the JSON dispatch path. Provider
/// integrations can advertise it via its `inputSchemaJSON`.
public struct ShellTool: Tool {
    public typealias Input = ShellInput
    public typealias Output = ShellResult

    public let name = "shell"
    public let description = "Run a shell command (cmd on Windows, /bin/sh elsewhere) and return stdout, stderr, exit code, and a timed-out flag."
    public let inputSchemaJSON = #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#

    private let executor: LocalShellExecutor

    public init(executor: LocalShellExecutor = LocalShellExecutor()) {
        self.executor = executor
    }

    public func invoke(_ input: Input) async throws -> Output {
        try await executor.execute(input.command)
    }
}
