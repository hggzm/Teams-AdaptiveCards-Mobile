import Foundation

/// Drives an interactive read-eval-print loop over a ``SwiftboxEnvironment``,
/// rendering to a ``TerminalFrontend``. This is the host-native frontend to the
/// *same* sandbox engine that runs on iOS: identical `Shell`, builtins, VFS,
/// package pipeline and persistence — only the input/output loop is host code.
///
/// The line source is injected (`nextLine`), so the whole loop is unit-tested
/// headlessly with a scripted source and a recording frontend; the executable
/// wires `nextLine` to the real console.
public final class ReplRunner {
    public let environment: SwiftboxEnvironment
    public let frontend: TerminalFrontend
    /// Whether to print a prompt before each read (true for an interactive TTY,
    /// false for piped/non-interactive input where prompts are just noise).
    public let interactive: Bool

    public private(set) var lastExitCode: Int32 = 0
    public private(set) var didExit = false

    /// Drives a full-screen editor to completion over the real console. When a
    /// prompt line launches `vi`/`vim`/`view <file>` interactively, the loop
    /// builds an ``EditorSession`` and hands it to this closure, which pumps raw
    /// keystrokes into it (`feedInput`) until it finishes. Injected by the
    /// executable (which owns the platform raw-mode terminal); left `nil` in
    /// headless/piped contexts, where an editor launch falls through to the
    /// ex-mode `vi` builtin instead. Keeping the platform code on the far side of
    /// this seam means the handoff is unit-tested with a scripted driver and no
    /// TTY.
    public var editorDriver: ((EditorSession) -> Void)?

    /// Reports the live console size used to lay out a full-screen editor.
    /// Defaults to a conventional 24×80; the executable overrides it to query the
    /// real terminal.
    public var consoleSize: () -> (rows: Int, columns: Int) = { (24, 80) }

    /// Opt-in **host passthrough** (off by default): when set, a *simple,
    /// non-builtin* command typed at the prompt is run as a real OS process via
    /// this runner — Termux-style reach-through to host tools swiftbox doesn't
    /// simulate. Builtins always win (they operate on the VFS sandbox); only an
    /// unrecognized command falls through, and only when it has no shell
    /// operators. The sandbox stays a sandbox unless the host explicitly enables
    /// this (e.g. `swiftbox --host-exec`). The same `NativeProcessRunner` seam
    /// powers on-device LiveProcess execution, so this is the desktop face of it.
    public var hostRunner: NativeProcessRunner?

    public init(environment: SwiftboxEnvironment, frontend: TerminalFrontend, interactive: Bool) {
        self.environment = environment
        self.frontend = frontend
        self.interactive = interactive
    }

    /// The prompt: `<cwd> <PS1>`, mirroring the interactive ``Session``.
    public var prompt: String {
        let ps1 = environment.shell.environment["PS1"] ?? "$ "
        return "\(environment.shell.cwd) \(ps1)"
    }

    /// A one-line banner shown at startup.
    public var banner: String {
        "swiftbox \(SwiftboxEnvironment.version) — sandbox shell (host: "
            + "\(ReplRunner.hostName)). Type 'help' for builtins, 'exit' to leave.\n"
    }

    static var hostName: String {
        #if os(Windows)
        return "windows"
        #elseif os(Linux)
        return "linux"
        #elseif os(macOS)
        return "macos"
        #else
        return "host"
        #endif
    }

    /// Run the loop, pulling input from `nextLine` until it returns nil or an
    /// `exit`/`quit` command runs. Returns the final exit code.
    @discardableResult
    public func run(nextLine: () -> String?) -> Int32 {
        if interactive { frontend.write(banner) }
        while true {
            if interactive { frontend.write(prompt) }
            guard let raw = nextLine() else { break }
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "exit" || trimmed == "quit" || trimmed.hasPrefix("exit ") {
                if trimmed.hasPrefix("exit "), let code = Int32(trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                    lastExitCode = code
                }
                didExit = true
                break
            }
            if trimmed.isEmpty { continue }

            // Full-screen editor handoff: on an interactive console with a
            // raw-mode driver available, `vi`/`vim`/`view <file>` takes over the
            // screen via the modal ``VisualEditor`` and returns on `:q`. Without
            // a driver (piped/headless) it falls through to the ex-mode builtin.
            if interactive, let editorDriver, let launch = Session.editorLaunch(for: trimmed) {
                environment.shell.recordHistory(line)
                let size = consoleSize()
                let editor = environment.shell.makeEditorSession(
                    path: launch, frontend: frontend,
                    rows: size.rows, columns: size.columns
                )
                editorDriver(editor)
                frontend.clearScreen()
                lastExitCode = 0
                continue
            }

            // Host passthrough: a non-builtin simple command runs on the real
            // host when enabled (see `hostRunner`). Builtins and any line with
            // shell operators stay with the interpreter.
            if let hostRunner, let hostResult = hostPassthrough(line, runner: hostRunner) {
                if !hostResult.stdout.isEmpty { frontend.write(hostResult.stdout) }
                if !hostResult.stderr.isEmpty { frontend.write(hostResult.stderr) }
                environment.shell.recordHistory(line)
                lastExitCode = hostResult.exitCode
                continue
            }

            let result = environment.shell.run(line)
            if !result.stdout.isEmpty { frontend.write(result.stdout) }
            if !result.stderr.isEmpty { frontend.write(result.stderr) }
            lastExitCode = result.exitCode
        }
        return lastExitCode
    }

    /// Decide whether `line` should run on the host instead of the interpreter,
    /// and if so run it. Returns `nil` (→ let the interpreter handle it) unless
    /// the line is a single command with **no shell operators**, whose head is
    /// **not a swiftbox builtin** and **does** resolve on the host. Any failure
    /// to spawn also returns `nil`, so the interpreter still gets its turn (and
    /// emits its own `command not found`).
    private func hostPassthrough(_ line: String, runner: NativeProcessRunner) -> CommandResult? {
        // Operators (pipes, redirection, sequencing) stay with the shell.
        if line.contains("|") || line.contains(">") || line.contains("<")
            || line.contains(";") || line.contains("&") { return nil }
        let argv = ShellParser.tokenize(line)
        guard let head = argv.first,
              !head.contains("="),                          // not an assignment
              !environment.shell.hasBuiltin(head)           // builtins win
        else { return nil }
        // Forward the shell's exported variables, but NOT its `PATH`: the sandbox
        // `PATH` points at the VFS (`$PREFIX/bin`), which would shadow the host's
        // real `PATH` and break the child's own command lookups. Dropping it lets
        // the host environment's `PATH` (from the runner's base) stand.
        let forwarded = environment.shell.environment.filter {
            $0.key.caseInsensitiveCompare("PATH") != .orderedSame
        }
        let invocation = ProcessInvocation(
            arguments: argv,
            environment: forwarded,
            workingDirectory: environment.shell.cwd
        )
        guard runner.canRun(invocation) else { return nil }
        return try? runner.run(invocation).commandResult
    }
}
