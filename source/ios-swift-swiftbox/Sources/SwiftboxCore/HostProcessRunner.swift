#if os(macOS) || os(Linux) || os(Windows)
import Foundation

/// A **real** ``NativeProcessRunner`` for desktop hosts (macOS / Linux /
/// Windows): it spawns an actual OS process via `Foundation.Process`, captures
/// stdout/stderr, feeds stdin, and maps the exit status back to a
/// ``ProcessExit``.
///
/// This is the cross-platform sibling of the Apple-only `LiveProcessRunner`
/// (which spawns inside the iOS sandbox via emexDE LiveProcess). Both conform to
/// the same ``NativeProcessRunner`` seam, so ``NativeKernel`` runs native code on
/// **every** target with one policy — host process here, LiveProcess on device —
/// and falls back to the interpreter only when neither can take an invocation.
/// The pure-Swift `StubProcessRunner` is now just for hermetic unit tests; this
/// is what actually runs programs on a real host.
///
/// `Foundation.Process` is unavailable on iOS/tvOS/watchOS, so this whole file is
/// compiled only for desktop OSes — the on-device path is `LiveProcessRunner`.
public final class HostProcessRunner: NativeProcessRunner {
    /// Resolves the logical executable (`arguments[0]` — typically a swiftbox VFS
    /// path or a bare command name) to a **real host filesystem path**, or `nil`
    /// if it cannot be run here. This is the host analogue of
    /// `LiveProcessRunner`'s bundle resolver: the host supplies it, e.g. backed by
    /// a ``HostExecutableStore`` that materializes a VFS-installed package binary,
    /// or by a PATH lookup (``pathResolving(baseEnvironment:)``).
    public typealias ExecutableResolver = (_ executable: String) -> String?

    private let resolve: ExecutableResolver
    private let baseEnvironment: [String: String]

    public init(
        resolve: @escaping ExecutableResolver,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.resolve = resolve
        self.baseEnvironment = baseEnvironment
    }

    /// A resolver closure that searches `PATH` (honoring `.exe`/`.bat`/`.cmd` on
    /// Windows) or accepts an existing absolute/relative path. Compose it as the
    /// fallback after a VFS-materializing resolver to get "installed-in-the-sandbox
    /// first, then real host tools".
    public static func pathResolver(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExecutableResolver {
        { HostProcessRunner.resolveOnPath($0, environment: baseEnvironment) }
    }

    /// A runner that resolves executables by absolute/relative path or by
    /// searching `PATH` (honoring `.exe`/`.bat`/`.cmd` on Windows). This is the
    /// "run real host commands" convenience.
    public static func pathResolving(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostProcessRunner {
        HostProcessRunner(
            resolve: pathResolver(baseEnvironment: baseEnvironment),
            baseEnvironment: baseEnvironment
        )
    }

    public func canRun(_ invocation: ProcessInvocation) -> Bool {
        guard let exe = invocation.arguments.first else { return false }
        return resolve(exe) != nil
    }

    public func run(_ invocation: ProcessInvocation) throws -> ProcessExit {
        guard let exe = invocation.arguments.first else {
            throw KernelError.executableNotFound("")
        }
        guard let hostPath = resolve(exe) else {
            throw KernelError.executableNotFound(exe)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hostPath)
        process.arguments = Array(invocation.arguments.dropFirst())

        // Inherit the host environment so PATH/loader vars resolve, then overlay
        // the invocation's own variables.
        var environment = baseEnvironment
        for (key, value) in invocation.environment { environment[key] = value }
        process.environment = environment

        // Only set the working directory when it actually exists on the host —
        // the swiftbox VFS cwd (e.g. "/data/swiftbox/home") usually does not, and
        // pointing Process at a missing directory makes `run()` throw.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: invocation.workingDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var inPipe: Pipe?
        if invocation.standardInput != nil {
            let pipe = Pipe()
            inPipe = pipe
            process.standardInput = pipe
        }

        // Drain both pipes on background queues *before* waiting: a child that
        // writes more than the pipe buffer (~64 KiB) would otherwise block
        // forever while we block on waitUntilExit().
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            outBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            throw KernelError.executableNotFound(hostPath)
        }

        if let stdin = invocation.standardInput, let inPipe {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        group.wait()

        // A process killed by a POSIX signal reports `.uncaughtSignal`; surface
        // that as `signal` so `ProcessExit.commandResult` maps it to 128+signal.
        // Windows has no POSIX signals (and doesn't reliably set
        // `terminationReason`), so there the status is always the exit code.
        #if os(Windows)
        let signal: Int32? = nil
        let exitCode: Int32 = process.terminationStatus
        #else
        let signal: Int32? = process.terminationReason == .uncaughtSignal
            ? process.terminationStatus : nil
        let exitCode: Int32 = process.terminationReason == .uncaughtSignal
            ? 0 : process.terminationStatus
        #endif

        return ProcessExit(
            standardOutput: String(decoding: outBox.value, as: UTF8.self),
            standardError: String(decoding: errBox.value, as: UTF8.self),
            exitCode: exitCode,
            signal: signal
        )
    }

    /// Resolve a command name against `PATH` (or accept an existing absolute /
    /// relative path). On Windows, tries the `PATHEXT`-style suffixes.
    static func resolveOnPath(_ name: String, environment: [String: String]) -> String? {
        let fm = FileManager.default

        #if os(Windows)
        let separator: Character = ";"
        let extensions = ["", ".exe", ".bat", ".cmd", ".com"]
        let pathSeparator = "\\"
        func runnable(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        #else
        let separator: Character = ":"
        let extensions = [""]
        let pathSeparator = "/"
        func runnable(_ path: String) -> Bool { fm.isExecutableFile(atPath: path) }
        #endif

        // An explicit path (contains a separator) is used as-is.
        if name.contains("/") || name.contains("\\") {
            for ext in extensions where runnable(name + ext) { return name + ext }
            return runnable(name) ? name : nil
        }

        let pathVar = HostProcessRunner.pathVariable(environment)
            ?? HostProcessRunner.pathVariable(ProcessInfo.processInfo.environment)
            ?? ""
        for dir in pathVar.split(separator: separator) {
            let base = "\(dir)\(pathSeparator)\(name)"
            for ext in extensions where runnable(base + ext) { return base + ext }
        }
        return nil
    }

    /// Look up the `PATH` variable, case-insensitively — on Windows the variable
    /// is conventionally spelled `Path`, and the environment dictionary is
    /// case-sensitive in Swift, so a plain `["PATH"]` lookup misses it.
    private static func pathVariable(_ environment: [String: String]) -> String? {
        if let direct = environment["PATH"] { return direct }
        for (key, value) in environment where key.caseInsensitiveCompare("PATH") == .orderedSame {
            return value
        }
        return nil
    }
}

/// A staging area that materializes swiftbox VFS executables onto the real host
/// filesystem so ``HostProcessRunner`` can launch them — the desktop analogue of
/// the iOS bundle the app registers for `LiveProcessRunner`. A package installed
/// into the VFS (`$PREFIX/bin/<tool>`) is copied out (and marked executable on
/// POSIX); the returned ``HostProcessRunner/ExecutableResolver`` then resolves
/// that VFS path to the materialized host path.
public final class HostExecutableStore {
    private let vfs: VirtualFileSystem
    /// Host directory the executables are materialized into.
    public let root: URL
    private var materialized: [String: String] = [:]

    public init(vfs: VirtualFileSystem, root: URL? = nil) throws {
        self.vfs = vfs
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftbox-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// Copy a VFS executable to the host staging dir and return its real path
    /// (cached). Returns `nil` if the VFS path is not a file.
    @discardableResult
    public func materialize(_ vfsPath: String) -> String? {
        if let cached = materialized[vfsPath] { return cached }
        guard vfs.isFile(vfsPath), let bytes = try? vfs.readFile(vfsPath) else { return nil }
        let name = (vfsPath as NSString).lastPathComponent
        let destination = root.appendingPathComponent(name)
        do {
            try bytes.write(to: destination)
        } catch {
            return nil
        }
        #if !os(Windows)
        // Mark 0755 so the host can exec it (POSIX only; Windows keys off the
        // file extension instead).
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        #endif
        let path = destination.path
        materialized[vfsPath] = path
        return path
    }

    /// A resolver for ``HostProcessRunner`` that materializes on demand. Bare
    /// names are resolved against the VFS `$PREFIX/bin` first; anything the store
    /// can't supply is handed to `fallback` (e.g. ``HostProcessRunner/pathResolver(baseEnvironment:)``),
    /// giving the Termux-style "installed-package binary first, then real host
    /// tools" lookup.
    public func resolver(
        searchBins: [String] = [SwiftboxEnvironment.prefix + "/bin"],
        fallback: HostProcessRunner.ExecutableResolver? = nil
    ) -> HostProcessRunner.ExecutableResolver {
        { [weak self] executable in
            guard let self else { return fallback?(executable) }
            if executable.hasPrefix("/"), let path = self.materialize(executable) { return path }
            for bin in searchBins {
                let candidate = bin + "/" + ((executable as NSString).lastPathComponent)
                if self.vfs.isFile(candidate), let path = self.materialize(candidate) { return path }
            }
            return fallback?(executable)
        }
    }
}

public extension NativeKernel {
    /// Build a kernel that prefers **real host process execution** (via
    /// ``HostProcessRunner``) and falls back to the environment's interpreter.
    /// This is the desktop counterpart to wiring `LiveProcessRunner` on iOS: the
    /// same *native-or-interpreter* policy, with a real OS process here.
    static func host(
        environment: SwiftboxEnvironment,
        runner: HostProcessRunner
    ) -> NativeKernel {
        NativeKernel(runner: runner, fallback: SimulatedKernel(shell: environment.shell))
    }
}

/// A small lock-guarded box so the two pipe-draining closures can hand their
/// captured `Data` back without tripping Swift's concurrent-capture checks.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
#endif
