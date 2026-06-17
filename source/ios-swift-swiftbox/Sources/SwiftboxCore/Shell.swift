import Foundation

/// The result of running a command line.
public struct CommandResult: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public static let success = CommandResult()
}

/// A builtin command: pure-Swift implementations of the userland utilities.
///
/// On stock iOS, an app cannot `fork`/`exec` arbitrary downloaded binaries, so
/// the most reliable way to ship a usable environment is to implement the core
/// utilities directly in Swift. This is the "basic interpreter" fallback: it
/// always works inside the sandbox, and native execution (the LiveProcess /
/// kernel backend) is layered on top later for performance-sensitive tools.
public typealias Builtin = (_ args: [String], _ shell: Shell) -> CommandResult

/// A line-oriented interpreter over a ``VirtualFileSystem`` and a
/// ``PackageRepository``. This is the swiftbox shell.
public final class Shell {
    public let vfs: VirtualFileSystem
    public let repository: PackageRepository
    public var environment: [String: String]
    public private(set) var cwd: String

    /// Optional package catalog + builder, wired by ``SwiftboxEnvironment`` so
    /// the `pkg` builtin can browse the catalog and build from it.
    public var catalog: PackageCatalog?
    public var builder: PackageBuilder?

    /// Optional on-disk package store and the key used to sign/verify its index.
    /// When set, `pkg update` / `pkg upgrade` operate against it.
    public var packageStore: LocalPackageStore?
    public var indexSigningKey: String = "swiftbox"
    /// The most recently fetched, verified package index (`pkg update`).
    public var packageIndex: PackageIndex?

    /// Optional source fetcher backing `pkg fetch` (fetch → verify → cache).
    public var sourceFetcher: SourceFetcher?

    /// Optional client for fetching a signed index from a remote URL
    /// (`pkg update <url>`).
    public var remoteIndexClient: RemoteIndexClient?

    /// Exit status of the most recently completed command (`$?`).
    public private(set) var lastExitCode: Int32 = 0

    /// Interactive command history (each top-level ``run(_:)`` line). Lines run
    /// while sourcing a script are not recorded, matching shell behavior.
    public private(set) var commandHistory: [String] = []
    private var historyRecording = true

    /// Standard input handed to the next builtin, set when running a pipeline.
    /// A builtin reads it via ``takePipedInput()``.
    private var pipedInput: String?

    private var builtins: [String: Builtin] = [:]

    public init(
        vfs: VirtualFileSystem,
        repository: PackageRepository,
        environment: [String: String] = [:],
        cwd: String = "/"
    ) {
        self.vfs = vfs
        self.repository = repository
        self.environment = environment
        self.cwd = cwd
        registerDefaults()
    }

    // MARK: Path helpers

    /// Resolve a (possibly relative) path against the current directory and
    /// normalize it.
    public func resolve(_ path: String) -> String {
        let base: String
        if path.hasPrefix("/") {
            base = path
        } else if cwd == "/" {
            base = "/" + path
        } else {
            base = cwd + "/" + path
        }
        if let comps = try? vfs.components(of: base) {
            return comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
        }
        return base
    }

    public func setCwd(_ path: String) throws {
        let resolved = resolve(path)
        guard vfs.isDirectory(resolved) else { throw VFSError.notADirectory(resolved) }
        cwd = resolved
    }

    // MARK: Builtin registry

    public func register(_ name: String, _ body: @escaping Builtin) {
        builtins[name] = body
    }

    public func hasBuiltin(_ name: String) -> Bool { builtins[name] != nil }

    public func builtinNames() -> [String] { builtins.keys.sorted() }

    // MARK: Execution

    /// Pop the piped standard input for a builtin (single-use).
    public func takePipedInput() -> String? {
        defer { pipedInput = nil }
        return pipedInput
    }

    /// Append a line to the interactive command history. Used by the
    /// interactive ``Session`` when it routes a command (e.g. an editor launch)
    /// outside the normal ``run(_:)`` path but still wants it recalled.
    public func recordHistory(_ line: String) {
        guard historyRecording else { return }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { commandHistory.append(line) }
    }

    /// Run a full command line. Supports statement separators (`;`), and/or
    /// connectors (`&&`, `||`), pipelines (`|`) and output redirection
    /// (`>`, `>>`). Updates ``lastExitCode``.
    @discardableResult
    public func run(_ line: String) -> CommandResult {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return .success }

        if historyRecording { commandHistory.append(line) }

        let tokens = ShellLexer.scan(trimmed)
        var result = CommandResult.success
        for statement in ShellLexer.split(tokens, on: ";") where !statement.isEmpty {
            result = evaluateAndOr(statement)
            lastExitCode = result.exitCode
        }
        return result
    }

    /// Evaluate an and/or list: pipelines joined by `&&` / `||` with
    /// short-circuit semantics.
    private func evaluateAndOr(_ tokens: [ShellLexer.Token]) -> CommandResult {
        let groups = ShellLexer.splitAndOr(tokens)
        var result = CommandResult.success
        var started = false
        for group in groups {
            if started {
                if group.connector == "&&" && result.exitCode != 0 { continue }
                if group.connector == "||" && result.exitCode == 0 { continue }
            }
            result = evaluatePipeline(group.tokens)
            lastExitCode = result.exitCode
            started = true
        }
        return result
    }

    /// Evaluate a pipeline: commands joined by `|`, feeding each stdout to the
    /// next command's stdin.
    private func evaluatePipeline(_ tokens: [ShellLexer.Token]) -> CommandResult {
        let stages = ShellLexer.split(tokens, on: "|")
        var input: String?
        var result = CommandResult.success
        for stage in stages {
            result = evaluateCommand(stage, stdin: input)
            input = result.stdout
        }
        return result
    }

    /// Evaluate a single command, applying any output redirection and stdin.
    private func evaluateCommand(_ tokens: [ShellLexer.Token], stdin: String?) -> CommandResult {
        // Split off a trailing redirection: `cmd ... > file` / `>> file`.
        var commandTokens = tokens
        var redirect: (path: String, append: Bool)?
        if let idx = tokens.lastIndex(where: { $0.isRedirection }) {
            let op = tokens[idx]
            let targetTokens = Array(tokens[(idx + 1)...])
            let words = wordList(targetTokens)
            guard let file = words.first else {
                return CommandResult(stderr: "swiftbox: syntax error near redirection\n", exitCode: 2)
            }
            redirect = (resolve(expand(file)), op.text == ">>")
            commandTokens = Array(tokens[..<idx])
        }

        let words = wordList(commandTokens)
        guard let command = words.first else { return .success }

        // A bare `NAME=value` assignment with no command.
        if words.count == 1, let result = tryAssignment(command) {
            return result
        }

        pipedInput = stdin
        let args = words.dropFirst().map(expand)
        let result: CommandResult
        if let builtin = builtins[command] {
            result = builtin(Array(args), self)
        } else {
            result = CommandResult(
                stderr: "swiftbox: \(command): command not found\n",
                exitCode: 127
            )
        }
        pipedInput = nil

        guard let redirect else { return result }
        do {
            if redirect.append, let existing = try? vfs.readString(redirect.path) {
                try vfs.writeFile(redirect.path, string: existing + result.stdout)
            } else {
                try vfs.writeFile(redirect.path, string: result.stdout)
            }
            return CommandResult(stdout: "", stderr: result.stderr, exitCode: result.exitCode)
        } catch {
            return CommandResult(stderr: "swiftbox: cannot write \(redirect.path)\n", exitCode: 1)
        }
    }

    /// Tokenize the concatenated segment text of `tokens` into shell words.
    private func wordList(_ tokens: [ShellLexer.Token]) -> [String] {
        let text = tokens.filter { !$0.isOperator }.map(\.text).joined()
        return ShellParser.tokenize(text)
    }

    /// Run a sequence of lines, stopping at the first non-zero exit code.
    @discardableResult
    public func runScript(_ lines: [String]) -> CommandResult {
        var last = CommandResult.success
        for line in lines {
            last = run(line)
            if last.exitCode != 0 { break }
        }
        return last
    }

    // MARK: Variable handling

    @discardableResult
    func tryAssignment(_ token: String) -> CommandResult? {
        guard let idx = token.firstIndex(of: "="), idx != token.startIndex else { return nil }
        let name = String(token[token.startIndex..<idx])
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        let value = String(token[token.index(after: idx)...])
        environment[name] = expand(value)
        return .success
    }

    /// Substitute `$NAME` and `${NAME}` references from the environment.
    public func expand(_ input: String) -> String {
        guard input.contains("$") else { return input }
        let chars = Array(input)
        var result = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "$" else {
                result.append(chars[i])
                i += 1
                continue
            }
            if i + 1 < chars.count && chars[i + 1] == "?" {
                result += String(lastExitCode)
                i += 2
                continue
            }
            if i + 1 < chars.count && chars[i + 1] == "{" {
                var j = i + 2
                var name = ""
                while j < chars.count && chars[j] != "}" { name.append(chars[j]); j += 1 }
                result += environment[name] ?? ""
                i = (j < chars.count) ? j + 1 : j
            } else {
                var j = i + 1
                var name = ""
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                    name.append(chars[j]); j += 1
                }
                if name.isEmpty {
                    result.append("$")
                    i += 1
                } else {
                    result += environment[name] ?? ""
                    i = j
                }
            }
        }
        return result
    }

    // MARK: Scripts

    /// Run a multi-line script in the current shell: each line is interpreted in
    /// order, output is concatenated, and execution continues past non-zero
    /// exits (shell scripts do not abort by default). Comments and blank lines
    /// are skipped. Returns the accumulated output and the last exit code.
    @discardableResult
    public func runSource(_ text: String) -> CommandResult {
        var out = ""
        var err = ""
        var code: Int32 = 0
        let previouslyRecording = historyRecording
        historyRecording = false
        defer { historyRecording = previouslyRecording }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let result = run(line)
            out += result.stdout
            err += result.stderr
            code = result.exitCode
        }
        return CommandResult(stdout: out, stderr: err, exitCode: code)
    }

    // MARK: Glob

    /// Minimal glob matcher supporting `*` and `?`, used by `find -name`.
    public static func globMatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let s = Array(name)
        // Classic two-pointer wildcard match.
        var pi = 0, si = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == s[si] || p[pi] == "?") {
                pi += 1; si += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: tr / sed helpers

    /// Expand a `tr` set, supporting simple `a-z` ranges.
    static func expandTrSet(_ set: String) -> String {
        let chars = Array(set)
        var out = ""
        var i = 0
        while i < chars.count {
            if i + 2 < chars.count && chars[i + 1] == "-" {
                let lo = chars[i].unicodeScalars.first!.value
                let hi = chars[i + 2].unicodeScalars.first!.value
                if lo <= hi {
                    for v in lo...hi { if let s = Unicode.Scalar(v) { out.append(Character(s)) } }
                    i += 3
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Parse a `sed` substitution `s/PATTERN/REPLACEMENT/[g]`. The delimiter is
    /// whatever character follows the leading `s`.
    static func parseSedSubstitution(_ script: String) -> (pattern: String, replacement: String, global: Bool)? {
        let chars = Array(script)
        guard chars.count >= 2, chars[0] == "s" else { return nil }
        let delim = chars[1]
        var fields: [String] = []
        var current = ""
        var escaped = false
        for ch in chars.dropFirst(2) {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == delim {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        guard fields.count >= 2 else { return nil }
        let flags = fields.count >= 3 ? fields[2] : ""
        return (fields[0], fields[1], flags.contains("g"))
    }
}
