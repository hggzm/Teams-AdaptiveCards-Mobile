import Foundation

/// Runs a real native process inside the iOS sandbox via a LiveProcess-style
/// runtime (emexDE / Nyxian). swiftbox does not own that boundary — it is
/// provided by the on-device app — so this protocol is the seam. It is pure
/// Swift (no Apple frameworks) so the *policy* (``NativeKernel``) is testable on
/// every platform; only the concrete adapter (`LiveProcessRunner`) is Apple-only.
///
/// The real backend maps an invocation onto emexDE's `PEProcessManager`
/// (`spawnProcessWithBundleIdentifier:…` → `pid_t`) and an `FDMapObject`
/// (`{ fd: FDObject }`) that redirects stdin/stdout/stderr so the result can be
/// captured. ``ProcessExit`` carries what that flow yields.
public protocol NativeProcessRunner: AnyObject {
    /// Whether `arguments[0]` can be executed natively right now (a launchable
    /// image exists and the runtime is available & permitted).
    func canRun(_ invocation: ProcessInvocation) -> Bool
    /// Spawn natively and wait for exit, returning the captured result. Throws
    /// ``KernelError`` when the runtime cannot take it (so the kernel can fall
    /// back to the interpreter).
    func run(_ invocation: ProcessInvocation) throws -> ProcessExit
}

/// The result of a native spawn: captured streams plus the exit status.
///
/// LiveProcess reports exit through `PEProcess.exitingCallback` and signals via
/// `sendSignal:`, so `signal` is set when a process was terminated by one.
public struct ProcessExit: Equatable {
    public var standardOutput: String
    public var standardError: String
    public var exitCode: Int32
    public var signal: Int32?

    public init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0, signal: Int32? = nil) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.signal = signal
    }

    /// Project onto the shell's ``CommandResult``. A signal maps to the
    /// conventional `128 + signal` exit code when no explicit code was set.
    public var commandResult: CommandResult {
        let code = signal.map { exitCode != 0 ? exitCode : 128 + $0 } ?? exitCode
        return CommandResult(stdout: standardOutput, stderr: standardError, exitCode: code)
    }
}

/// Kernel that prefers native on-device execution and falls back to the
/// pure-Swift interpreter.
///
/// Realizes the roadmap's Phase 3 policy: *native when available & permitted,
/// interpreter otherwise.* It performs no `fork`/`exec` itself (forbidden on
/// stock iOS) — it delegates to a ``NativeProcessRunner`` and degrades to a
/// wrapped ``SimulatedKernel`` when native execution is unavailable.
public final class NativeKernel: Kernel {
    public let name = "native+simulated"

    private let runner: NativeProcessRunner?
    private let fallback: Kernel

    public init(runner: NativeProcessRunner?, fallback: Kernel) {
        self.runner = runner
        self.fallback = fallback
    }

    /// Convenience: build over an environment's shell, reusing its interpreter.
    public convenience init(environment: SwiftboxEnvironment, runner: NativeProcessRunner? = nil) {
        self.init(runner: runner, fallback: SimulatedKernel(shell: environment.shell))
    }

    public func spawn(_ invocation: ProcessInvocation) throws -> CommandResult {
        if let runner, runner.canRun(invocation) {
            do {
                return try runner.run(invocation).commandResult
            } catch KernelError.executableNotFound, KernelError.unsupportedOnPlatform {
                // Native couldn't take it after all — degrade to the interpreter.
                return try fallback.spawn(invocation)
            }
        }
        return try fallback.spawn(invocation)
    }
}

/// A test/desktop runner that "runs" only executables present in a
/// ``VirtualFileSystem`` (e.g. produced by ``NativeBuildBackend``), returning a
/// canned ``ProcessExit``. Lets the native-execution policy be exercised without
/// the LiveProcess runtime.
public final class StubProcessRunner: NativeProcessRunner {
    private let vfs: VirtualFileSystem
    /// Maps an executable path to the result it should produce.
    public var results: [String: ProcessExit] = [:]
    public private(set) var ran: [ProcessInvocation] = []

    public init(vfs: VirtualFileSystem) {
        self.vfs = vfs
    }

    public func canRun(_ invocation: ProcessInvocation) -> Bool {
        guard let exe = invocation.arguments.first else { return false }
        return vfs.isFile(exe)
    }

    public func run(_ invocation: ProcessInvocation) throws -> ProcessExit {
        guard let exe = invocation.arguments.first, vfs.isFile(exe) else {
            throw KernelError.executableNotFound(invocation.arguments.first ?? "")
        }
        ran.append(invocation)
        return results[exe] ?? ProcessExit(standardOutput: "ran \(exe)\n", exitCode: 0)
    }
}
