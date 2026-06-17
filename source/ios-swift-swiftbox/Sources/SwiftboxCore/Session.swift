import Foundation

/// A single interactive session: it binds a ``Shell`` to a ``TerminalEmulator``,
/// keeps command history, and renders a prompt + command output onto the grid.
///
/// This is the foundation the eventual on-device terminal *view* attaches to:
/// the SwiftUI layer will own a ``Session``, feed it keystrokes/lines, and draw
/// the emulator's grid. Keeping it in the pure-Swift core means the whole
/// interactive loop is testable on the desktop with no UI.
public final class Session {
    public let shell: Shell
    public let terminal: TerminalEmulator
    /// Where rendered output is written. Defaults to the built-in
    /// ``TerminalEmulator`` (headless), but an Apple app can supply a
    /// terminal-view-backed ``TerminalFrontend`` (e.g. SwiftTerm) so the same
    /// interactive loop drives a real on-device terminal.
    public let frontend: TerminalFrontend

    /// The interactive line editor, fed decoded keystrokes via ``feedInput(_:)``.
    public let lineEditor: LineEditor

    /// Command history in entry order (most recent last). Sourced from the
    /// shell, which records every interactive line.
    public var history: [String] { shell.commandHistory }

    /// Whether the last command set a non-zero exit code.
    public var lastExitCode: Int32 { shell.lastExitCode }

    public init(shell: Shell, rows: Int = 24, columns: Int = 80, frontend: TerminalFrontend? = nil) {
        self.shell = shell
        let emulator = TerminalEmulator(rows: rows, columns: columns)
        self.terminal = emulator
        self.frontend = frontend ?? emulator
        self.lineEditor = LineEditor(history: shell.commandHistory)
        promptShown = false
    }

    private var promptShown: Bool

    /// The prompt string, derived from `PS1` (default `$ `) prefixed with the
    /// current working directory, mirroring a typical interactive shell.
    public var prompt: String {
        let ps1 = shell.environment["PS1"] ?? "$ "
        return "\(shell.cwd) \(ps1)"
    }

    /// Run a line as if typed at the prompt: echo the prompt + line, run it,
    /// feed stdout/stderr to the terminal, and record history (via the shell).
    /// Returns the command result.
    @discardableResult
    public func enter(_ line: String) -> CommandResult {
        frontend.write(prompt + line + "\n")
        let result = shell.run(line)
        if !result.stdout.isEmpty { frontend.write(result.stdout) }
        if !result.stderr.isEmpty { frontend.write(result.stderr) }
        return result
    }

    // MARK: Interactive input

    /// Show the prompt for a fresh input line (idempotent until a line submits).
    public func showPrompt() {
        guard !promptShown else { return }
        lineEditor.setHistory(shell.commandHistory)
        lineEditor.reset()
        frontend.write(prompt)
        promptShown = true
    }

    /// Feed raw terminal input (keystrokes, possibly with escape sequences) into
    /// the interactive editor. On each Enter the buffered line is run and its
    /// output rendered. If a line launches a full-screen editor (`vi`/`vim`/
    /// `view` <file>, interactively), control hands off to an ``EditorSession``
    /// and the remaining keystrokes drive it until `:q`. Returns the results of
    /// any shell commands submitted.
    @discardableResult
    public func feedInput(_ input: String) -> [CommandResult] {
        let keys = KeyDecoder.decode(input)
        var results: [CommandResult] = []
        var i = 0
        while i < keys.count {
            // While a full-screen editor owns the screen, route the rest of the
            // keystroke stream straight to it.
            if let editor = activeEditor {
                let stillOpen = editor.feedKeys(Array(keys[i...]))
                i = keys.count
                if !stillOpen { closeEditor() }
                break
            }

            showPrompt()
            let key = keys[i]
            i += 1
            let outcome = lineEditor.feed(key)
            switch outcome {
            case .submit(let line):
                frontend.write("\n")
                promptShown = false
                if let path = Session.editorLaunch(for: line) {
                    shell.recordHistory(line)
                    let editor = EditorSession(
                        shell: shell, path: path,
                        frontend: frontend,
                        rows: terminal.rows, columns: terminal.columns
                    )
                    editor.redraw()
                    activeEditor = editor
                } else {
                    let result = shell.run(line)
                    if !result.stdout.isEmpty { frontend.write(result.stdout) }
                    if !result.stderr.isEmpty { frontend.write(result.stderr) }
                    results.append(result)
                    showPrompt()
                }
            case .updated:
                redrawInputLine()
            case .ignored:
                break
            }
        }
        return results
    }

    /// Whether a full-screen editor currently owns the screen.
    public var isEditing: Bool { activeEditor != nil }

    private var activeEditor: EditorSession?

    /// Tear down the editor and return to a fresh prompt.
    private func closeEditor() {
        activeEditor = nil
        terminal.clear()
        promptShown = false
        showPrompt()
    }

    /// If `line` is an interactive full-screen editor launch (`vi`/`vim`/`view`,
    /// no `-c` startup commands), return the file to edit (nil for a scratch
    /// buffer). A `-c`/piped invocation stays with the ex-mode builtin instead.
    static func editorLaunch(for line: String) -> String?? {
        let words = ShellParser.tokenize(line)
        guard let cmd = words.first, ["vi", "vim", "view"].contains(cmd) else { return nil }
        let args = Array(words.dropFirst())
        if args.contains("-c") { return nil }
        let file = args.first { !$0.hasPrefix("-") }
        return .some(file)
    }

    /// Repaint the current input line in place: carriage-return, prompt, buffer,
    /// clear-to-end, then position the cursor.
    private func redrawInputLine() {
        var out = "\r" + prompt + lineEditor.buffer + "\u{1b}[K"
        let trailing = lineEditor.buffer.count - lineEditor.cursor
        if trailing > 0 { out += "\u{1b}[\(trailing)D" }
        frontend.write(out)
    }

    /// History entry at `offset` from the end (1 = most recent), or nil.
    public func recall(_ offset: Int) -> String? {
        guard offset >= 1, offset <= history.count else { return nil }
        return history[history.count - offset]
    }

    /// Render the `n` most recent history entries, numbered like the `history`
    /// builtin (oldest of the slice first).
    public func renderHistory(limit: Int = 0) -> String {
        let entries = limit > 0 ? Array(history.suffix(limit)) : history
        let start = history.count - entries.count
        var out = ""
        for (i, entry) in entries.enumerated() {
            out += "\(start + i + 1)  \(entry)\n"
        }
        return out
    }

    /// The current terminal grid as text.
    public func screen() -> String { terminal.snapshot() }
}
