import Foundation

/// The editor family: `ed`, `ex`, `vi`, and `vim`, all backed by ``EdEditor``.
///
/// `ed` is the genuine line editor and reads its command script from stdin
/// (pipe a script in, classic Unix style). `ex`/`vi`/`vim` are the line/"ex"
/// mode of the visual editor: they additionally accept `-c 'cmd'` startup
/// commands and tolerate a leading `:` and `%` (whole-file) address. Full
/// **visual** (full-screen) mode is the next leg; until then a non-interactive
/// invocation runs in ex mode so the editor is still fully usable and testable
/// in the simulation — no device required.
extension Shell {
    func registerEditors() {
        register("ed") { args, shell in
            shell.runLineEditor(program: "ed", args: args, exMode: false)
        }
        for name in ["ex", "vi", "vim"] {
            register(name) { args, shell in
                shell.runLineEditor(program: name, args: args, exMode: true)
            }
        }
    }

    /// Load a VFS file (if present) into editor lines.
    private func editorLoad(_ path: String) -> [String] {
        guard vfs.isFile(path), let text = try? vfs.readString(path) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Rewrite ex-style command lines into `ed` syntax: drop a single leading
    /// `:` and expand a leading `%` address to `1,$`.
    private static func exNormalize(_ script: String) -> String {
        script.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            var line = String(raw)
            if line.hasPrefix(":") { line.removeFirst() }
            if line.hasPrefix("%") { line = "1,$" + line.dropFirst() }
            return line
        }.joined(separator: "\n")
    }

    func runLineEditor(program: String, args: [String], exMode: Bool) -> CommandResult {
        var silent = false
        var startupCommands: [String] = []
        var filename: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-s", "-e":
                silent = true
            case "-c":
                if exMode, i + 1 < args.count { startupCommands.append(args[i + 1]); i += 1 }
            default:
                if !a.hasPrefix("-"), filename == nil { filename = a }
            }
            i += 1
        }

        var scriptParts: [String] = []
        if exMode { scriptParts.append(contentsOf: startupCommands) }
        if let piped = takePipedInput() { scriptParts.append(piped) }
        var script = scriptParts.joined(separator: "\n")
        if exMode { script = Shell.exNormalize(script) }

        // A non-interactive editor invocation with no commands can't enter the
        // (not-yet-implemented) visual mode — report that and stop, but treat it
        // as success so scripts that merely "open" a file don't fail.
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if program == "ed" { return .success }
            let note = silent ? "" :
                "\(program): full-screen visual mode runs through an interactive terminal " +
                "(EditorSession); in a non-interactive shell, pass ex commands via stdin or " +
                "-c 'cmd' (e.g. vi -c '%s/a/b/g' -c 'wq' file).\n"
            return CommandResult(stderr: note, exitCode: 0)
        }

        let absFile = filename.map { resolve($0) }
        var editor = EdEditor(lines: absFile.map(editorLoad) ?? [], filename: filename)
        let result = editor.run(script)

        for write in result.writes {
            let target = write.file.map { resolve($0) } ?? absFile
            guard let path = target else {
                return CommandResult(
                    stdout: result.output,
                    stderr: "\(program): no current filename\n",
                    exitCode: 1
                )
            }
            do { try vfs.writeFile(path, string: write.contents) }
            catch { return CommandResult(stdout: result.output, stderr: "\(program): cannot write \(path)\n", exitCode: 1) }
        }

        return CommandResult(stdout: result.output, exitCode: result.hadError ? 1 : 0)
    }
}
