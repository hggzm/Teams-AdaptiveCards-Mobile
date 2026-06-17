import Foundation

/// Errors a ``Kernel`` backend may raise.
public enum KernelError: Error, Equatable {
    case unsupportedOnPlatform(String)
    case executableNotFound(String)
    case permissionDenied(String)
}

/// A request to run a program.
public struct ProcessInvocation: Equatable {
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    /// Optional standard input piped to the process. On the LiveProcess backend
    /// this becomes an `FDObject` mapped to fd 0 in the spawn's `FDMapObject`.
    public var standardInput: String?

    public init(
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String = "/",
        standardInput: String? = nil
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }
}

/// The "virtual kernel" abstraction.
///
/// Termux relies on Android letting an app `exec` downloaded ELF binaries.
/// Stock iOS forbids that, so emexDE/Nyxian-style projects interpose a kernel
/// virtualization layer (LiveProcess) that handles syscalls and sub-processing
/// for code running inside the app's sandbox. swiftbox models that boundary as
/// this protocol so the engine never assumes a particular execution strategy:
///
/// * ``SimulatedKernel`` — pure Swift, routes everything through the builtin
///   interpreter. Always available, including on Linux/Windows CI and inside
///   the iOS sandbox with no entitlements. This is the reliable baseline.
/// * `NativeKernel` (future, Apple-only) — backs invocations with the
///   LiveProcess syscall-handling layer to run a real on-device toolchain.
public protocol Kernel: AnyObject {
    var name: String { get }
    func spawn(_ invocation: ProcessInvocation) throws -> CommandResult
}

/// Pure-Swift kernel backend: every invocation is reconstructed into a command
/// line and executed by the builtin interpreter. No native process is created,
/// so this works anywhere Swift runs.
public final class SimulatedKernel: Kernel {
    public let name = "simulated"
    private let shell: Shell

    public init(shell: Shell) {
        self.shell = shell
    }

    public func spawn(_ invocation: ProcessInvocation) throws -> CommandResult {
        guard !invocation.arguments.isEmpty else { return .success }
        let line = invocation.arguments.map(Self.quoteIfNeeded).joined(separator: " ")
        return shell.run(line)
    }

    private static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty || s.contains(" ") || s.contains("\t") {
            return "\"\(s)\""
        }
        return s
    }
}
