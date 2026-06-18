import Foundation

/// Translates a **declarative** Jenkinsfile into a swiftci `Pipeline`.
///
/// Scope (Phase 15):
///
/// - Top-level `pipeline { ... }` block is required. Scripted
///   pipelines (`node { ... }`, top-level `def`, raw Groovy)
///   throw `ParseError.scripted`.
/// - `stages { stage('X') { steps { sh '…' } } }` maps to one
///   swiftci `Step` per stage. Multiple `sh` / `bat` / `pwsh` lines
///   inside a stage are concatenated with newlines into the step's
///   `run:`.
/// - Top-level `environment { K = 'V' }` and per-stage
///   `environment { ... }` merge into the step's `env:`. Per-stage
///   overrides top-level.
/// - `archiveArtifacts artifacts: 'pattern'` (and bare
///   `archiveArtifacts 'pattern'`) appends to the step's `artifacts:`.
/// - `post { failure { httpRequest url: 'https://…' } }` maps to
///   swiftci `notify:` with `on: failed`. `always`/`success`/`failure`
///   map to swiftci's `.always`/`.passed`/`.failed`. `aborted` and
///   `unstable` also map to `.failed` for now (swiftci treats
///   `.canceled` as not-clean-pass).
/// - `withEnv(['K=V']) { sh '…' }` inlines as `export K=V` lines
///   before the inner commands (POSIX shells only).
/// - `dir('subdir') { sh '…' }` inlines as `cd subdir`.
/// - `echo 'msg'` translates to `echo <quoted-msg>`.
///
/// Out of scope (warnings, never errors):
///
/// - `agent { ... }`, `when { ... }`, `options { ... }`,
///   `triggers { ... }`, `tools { ... }`,
///   `script { ... }` — preserved-as-comments / dropped with a
///   warning.
/// - `parameters { string(name:'X', defaultValue:'Y') }`,
///   `booleanParam`, `choice` — the default value (or first choice)
///   is merged into the global env so steps can reference the
///   parameter as a regular env var. Other parameter kinds are
///   dropped with a warning. (Phase 24)
/// - `parallel { ... }` — translated into a single swiftci Step whose
///   `parallel:` carries one branch per inner `stage`. Branches run
///   concurrently inside the executor's TaskGroup (Phase 36).
/// - Plugin steps (`mail`, `slackSend`, `junit`, …) — dropped with a
///   warning that points users at swiftci's own `notify:` / artifact
///   collection.
///
/// The importer is deliberately tolerant: unknown identifiers
/// generate warnings, not errors. Visit `result.warnings` to see
/// everything that wasn't translated.
public struct JenkinsfileImporter {

    public struct Result {
        public let pipeline: Pipeline
        public let warnings: [String]
        public init(pipeline: Pipeline, warnings: [String]) {
            self.pipeline = pipeline
            self.warnings = warnings
        }
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        /// File looks like a scripted Jenkinsfile (`node { ... }` or
        /// top-level Groovy). Not supported.
        case scripted
        /// No `pipeline { ... }` block at the top level.
        case noPipelineBlock
        case unterminatedString(line: Int)
        case unexpected(line: Int, message: String)

        public var description: String {
            switch self {
            case .scripted:
                return "scripted Jenkinsfile detected; only declarative pipelines are supported"
            case .noPipelineBlock:
                return "no `pipeline { ... }` block found at top level"
            case .unterminatedString(let line):
                return "unterminated string starting at line \(line)"
            case .unexpected(let line, let message):
                return "line \(line): \(message)"
            }
        }
    }

    public static func parse(
        _ source: String,
        defaultName: String = "Imported"
    ) throws -> Result {
        var lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens: tokens, defaultName: defaultName)
        return try parser.parsePipeline()
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Tokens
// ────────────────────────────────────────────────────────────────────

private enum Token: Equatable {
    case ident(String, line: Int)
    case string(String, line: Int)
    case number(String, line: Int)
    case lbrace(Int)
    case rbrace(Int)
    case lparen(Int)
    case rparen(Int)
    case lbracket(Int)
    case rbracket(Int)
    case comma(Int)
    case colon(Int)
    case equals(Int)
    case newline(Int)
    case eof

    var line: Int {
        switch self {
        case .ident(_, let l), .string(_, let l), .number(_, let l): return l
        case .lbrace(let l), .rbrace(let l), .lparen(let l), .rparen(let l),
             .lbracket(let l), .rbracket(let l),
             .comma(let l), .colon(let l), .equals(let l), .newline(let l):
            return l
        case .eof: return 0
        }
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Lexer
// ────────────────────────────────────────────────────────────────────

private struct Lexer {
    let source: [Character]
    var idx: Int = 0
    var line: Int = 1

    init(source: String) {
        self.source = Array(source)
    }

    mutating func tokenize() throws -> [Token] {
        var out: [Token] = []
        while idx < source.count {
            let c = source[idx]
            switch c {
            case " ", "\t", "\r":
                idx += 1
            case "\n":
                out.append(.newline(line))
                line += 1
                idx += 1
            case "/":
                if idx + 1 < source.count {
                    let n = source[idx + 1]
                    if n == "/" {
                        while idx < source.count && source[idx] != "\n" { idx += 1 }
                        continue
                    }
                    if n == "*" {
                        idx += 2
                        while idx + 1 < source.count {
                            if source[idx] == "*" && source[idx + 1] == "/" {
                                idx += 2
                                break
                            }
                            if source[idx] == "\n" { line += 1 }
                            idx += 1
                        }
                        continue
                    }
                }
                // bare '/' — treat as unknown punctuation, skip.
                idx += 1
            case "{": out.append(.lbrace(line)); idx += 1
            case "}": out.append(.rbrace(line)); idx += 1
            case "(": out.append(.lparen(line)); idx += 1
            case ")": out.append(.rparen(line)); idx += 1
            case "[": out.append(.lbracket(line)); idx += 1
            case "]": out.append(.rbracket(line)); idx += 1
            case ",": out.append(.comma(line)); idx += 1
            case ":": out.append(.colon(line)); idx += 1
            case "=": out.append(.equals(line)); idx += 1
            case ";":
                // Treat semicolons as newlines.
                out.append(.newline(line))
                idx += 1
            case "'", "\"":
                let s = try scanString(quote: c)
                out.append(.string(s.value, line: s.line))
            default:
                if c.isLetter || c == "_" || c == "@" || c == "$" {
                    let id = scanIdent()
                    out.append(.ident(id, line: line))
                } else if c.isNumber {
                    let n = scanNumber()
                    out.append(.number(n, line: line))
                } else {
                    // Unknown punctuation — skip silently.
                    idx += 1
                }
            }
        }
        out.append(.eof)
        return out
    }

    private mutating func scanString(quote: Character)
        throws -> (value: String, line: Int)
    {
        let startLine = line
        // Detect triple quotes: ''' or """
        let triple = (idx + 2 < source.count
                      && source[idx + 1] == quote
                      && source[idx + 2] == quote)
        if triple {
            idx += 3
        } else {
            idx += 1
        }

        var buf = ""
        while idx < source.count {
            let c = source[idx]
            if c == "\\" && !triple {
                idx += 1
                if idx >= source.count { break }
                let esc = source[idx]
                switch esc {
                case "n":  buf.append("\n")
                case "t":  buf.append("\t")
                case "r":  buf.append("\r")
                case "'", "\"", "\\": buf.append(esc)
                case "$":  buf.append("$")
                default:   buf.append("\\"); buf.append(esc)
                }
                idx += 1
                continue
            }
            if c == quote {
                if triple {
                    if idx + 2 < source.count
                        && source[idx + 1] == quote
                        && source[idx + 2] == quote {
                        idx += 3
                        return (buf, startLine)
                    }
                } else {
                    idx += 1
                    return (buf, startLine)
                }
            }
            if c == "\n" {
                if !triple {
                    throw JenkinsfileImporter.ParseError
                        .unterminatedString(line: startLine)
                }
                line += 1
            }
            buf.append(c)
            idx += 1
        }
        throw JenkinsfileImporter.ParseError.unterminatedString(line: startLine)
    }

    private mutating func scanIdent() -> String {
        var buf = ""
        while idx < source.count {
            let c = source[idx]
            if c.isLetter || c.isNumber || c == "_" || c == "." {
                buf.append(c)
                idx += 1
            } else {
                break
            }
        }
        return buf
    }

    private mutating func scanNumber() -> String {
        var buf = ""
        while idx < source.count {
            let c = source[idx]
            if c.isNumber || c == "." {
                buf.append(c)
                idx += 1
            } else {
                break
            }
        }
        return buf
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Parser
// ────────────────────────────────────────────────────────────────────

private struct Parser {
    let tokens: [Token]
    var pos: Int = 0
    let defaultName: String
    var warnings: [String] = []

    init(tokens: [Token], defaultName: String) {
        self.tokens = tokens
        self.defaultName = defaultName
    }

    mutating func parsePipeline() throws -> JenkinsfileImporter.Result {
        skipNewlines()
        // First top-level identifier must be `pipeline`. Detect a few
        // common scripted/legacy entry points and bail explicitly.
        guard case .ident(let s, _) = peek() else {
            throw JenkinsfileImporter.ParseError.noPipelineBlock
        }
        if s == "node" || s == "def" || s == "stage" {
            throw JenkinsfileImporter.ParseError.scripted
        }
        guard s == "pipeline" else {
            throw JenkinsfileImporter.ParseError.noPipelineBlock
        }
        _ = advance()                  // pipeline
        try expectLBrace()

        var name = defaultName
        var globalEnv: [String: String] = [:]
        var steps: [Pipeline.Step] = []
        var notifications: [Pipeline.Notification] = []

        skipNewlines()
        while case .ident(let kw, let line) = peek() {
            _ = advance()
            switch kw {
            case "agent":
                skipAgent()
            case "environment":
                let env = try parseEnvironment()
                for (k, v) in env { globalEnv[k] = v }
            case "parameters":
                // Phase 24: top-level `parameters { ... }` block.
                // Recognised entries:
                //   string(name: 'X', defaultValue: 'Y')
                //   booleanParam(name: 'X', defaultValue: true)
                //   choice(name: 'X', choices: ['a', 'b'])
                // Each becomes a default env var available to every
                // step. POSIX-friendly: booleans stringify to
                // "true"/"false"; choice default is the first entry.
                // Anything else inside the block is dropped with a
                // warning.
                let params = try parseParameters()
                for (k, v) in params { globalEnv[k] = v }
            case "options", "triggers", "tools", "libraries":
                warnings.append("line \(line): top-level `\(kw)` block ignored")
                skipBlockOrCall()
            case "stages":
                steps = try parseStages(globalEnv: globalEnv)
            case "post":
                let n = try parsePost()
                notifications.append(contentsOf: n)
            default:
                warnings.append("line \(line): unknown top-level keyword `\(kw)`")
                skipBlockOrCall()
            }
            skipNewlines()
        }

        try expectRBrace()

        // Allow a `// name: My Build` magic comment? Simpler: keep the
        // caller-provided defaultName.
        _ = name

        let pipeline = Pipeline(
            name: defaultName,
            steps: steps,
            notify: notifications,
            retention: nil,
            triggers: []
        )
        return JenkinsfileImporter.Result(
            pipeline: pipeline, warnings: warnings)
    }

    // ──────────────────────────────────────────────────────────────
    // stages { stage('name') { ... } stage('next') { ... } }
    // ──────────────────────────────────────────────────────────────

    private mutating func parseStages(
        globalEnv: [String: String]
    ) throws -> [Pipeline.Step] {
        try expectLBrace()
        var out: [Pipeline.Step] = []
        skipNewlines()
        while case .ident(let s, let line) = peek() {
            if s != "stage" {
                warnings.append("line \(line): expected `stage`, got `\(s)`")
                _ = advance()
                skipBlockOrCall()
                skipNewlines()
                continue
            }
            _ = advance()                  // stage
            try expectLParen()
            let stageName: String
            if case .string(let n, _) = peek() {
                _ = advance()
                stageName = n
            } else {
                throw JenkinsfileImporter.ParseError.unexpected(
                    line: peek().line,
                    message: "expected stage name string after `stage(`")
            }
            try expectRParen()
            try expectLBrace()

            var stageEnv = globalEnv
            var commands: [String] = []
            var artifacts: [String] = []
            var sawParallel = false
            var stageCondition: Pipeline.StepCondition? = nil
            var stageCreds: [Pipeline.CredentialBinding] = []

            skipNewlines()
            while case .ident(let kw, let ln) = peek() {
                _ = advance()
                switch kw {
                case "agent":
                    skipAgent()
                case "when":
                    // Phase 32: parse declarative `when {}` predicates
                    // we can model. Anything we can't model produces a
                    // warning and is dropped from the predicate (so a
                    // partial-success when-block degrades to "match
                    // anything we did parse").
                    if let cond = try parseWhen(stageName: stageName, headerLine: ln) {
                        stageCondition = cond
                    }
                case "options", "tools", "input":
                    warnings.append("stage '\(stageName)' (line \(ln)): `\(kw)` block ignored")
                    skipBlockOrCall()
                case "environment":
                    let env = try parseEnvironment()
                    for (k, v) in env { stageEnv[k] = v }
                case "steps":
                    let (cmds, arts, creds) = try parseSteps()
                    commands.append(contentsOf: cmds)
                    artifacts.append(contentsOf: arts)
                    stageCreds.append(contentsOf: creds)
                case "parallel":
                    sawParallel = true
                    let parallelSteps = try parseParallel(globalEnv: stageEnv)
                    // Flatten: append each parallel branch as its own
                    // top-level step.
                    out.append(contentsOf: parallelSteps)
                case "post":
                    warnings.append("stage '\(stageName)' (line \(ln)): per-stage `post` block ignored")
                    skipBlockOrCall()
                case "matrix":
                    warnings.append("stage '\(stageName)' (line \(ln)): `matrix` block ignored")
                    skipBlockOrCall()
                default:
                    warnings.append("stage '\(stageName)' (line \(ln)): unknown stage keyword `\(kw)`")
                    skipBlockOrCall()
                }
                skipNewlines()
            }
            try expectRBrace()

            if sawParallel && commands.isEmpty {
                // The parallel branches were already appended; the
                // wrapping stage itself becomes an empty marker — skip.
            } else if !commands.isEmpty {
                // De-dupe credential bindings by variable, preserving
                // first-seen order. The schema validation in
                // `Pipeline.Step` rejects duplicates outright; we
                // collapse them here so a stage that wraps the same
                // `withCredentials` block more than once still imports.
                var seenVar: Set<String> = []
                var creds: [Pipeline.CredentialBinding] = []
                for b in stageCreds where seenVar.insert(b.variable).inserted {
                    creds.append(b)
                }
                out.append(Pipeline.Step(
                    name: stageName,
                    run: commands.joined(separator: "\n"),
                    env: stageEnv,
                    artifacts: artifacts,
                    condition: stageCondition,
                    credentials: creds
                ))
            } else {
                warnings.append("stage '\(stageName)': no steps captured")
            }
            skipNewlines()
        }
        try expectRBrace()
        return out
    }

    private mutating func parseParallel(
        globalEnv: [String: String]
    ) throws -> [Pipeline.Step] {
        // Phase 36: a Jenkins `parallel { stage('A') { … } stage('B')
        // { … } }` block is now translated into a single swiftci Step
        // whose `parallel:` carries one branch per stage. The branches
        // run concurrently inside the executor's TaskGroup. Each
        // branch holds the stage's converted Step(s) as sequential
        // sub-steps.
        let stages = try parseStages(globalEnv: globalEnv)
        if stages.isEmpty {
            warnings.append("`parallel { … }` block had no stages — skipped")
            return []
        }
        let branches: [Pipeline.ParallelBranch] = stages.map { st in
            // Drop any `parallel:` nesting that snuck in (defence in
            // depth — parseStages doesn't currently emit nested
            // parallels, but if it ever does we flatten by ignoring
            // the inner group rather than failing the import).
            let flat = Pipeline.Step(
                name: st.name,
                run: st.run.isEmpty ? "true" : st.run,
                env: st.env,
                artifacts: st.artifacts,
                condition: st.condition,
                parallel: nil)
            return Pipeline.ParallelBranch(name: st.name, steps: [flat])
        }
        return [Pipeline.Step(
            name: "parallel",
            run: "",
            env: [:],
            artifacts: [],
            condition: nil,
            parallel: branches)]
    }

    // ──────────────────────────────────────────────────────────────
    // steps { sh '...' echo '...' archiveArtifacts ... }
    // ──────────────────────────────────────────────────────────────

    private mutating func parseSteps() throws
        -> (cmds: [String], artifacts: [String], credentials: [Pipeline.CredentialBinding])
    {
        try expectLBrace()
        var cmds: [String] = []
        var arts: [String] = []
        var creds: [Pipeline.CredentialBinding] = []
        skipNewlines()
        while case .ident(let s, let line) = peek() {
            _ = advance()
            switch s {
            case "sh":
                cmds.append(try parseShStyle())
            case "bat":
                warnings.append("line \(line): `bat` preserved verbatim — Windows-only")
                cmds.append(try parseShStyle())
            case "pwsh", "powershell":
                cmds.append(try parseShStyle())
            case "echo":
                let msg = try parseFirstStringArg() ?? ""
                cmds.append("echo \(quoteForShell(msg))")
            case "archiveArtifacts":
                let pattern = try parseNamedOrFirstString(name: "artifacts")
                if let p = pattern {
                    arts.append(p)
                } else {
                    warnings.append("line \(line): archiveArtifacts had no pattern")
                }
                consumeRestOfStatement()
            case "junit":
                if let p = try parseFirstStringArg() {
                    arts.append(p)
                    warnings.append("line \(line): `junit '\(p)'` collected as plain artifact (no JUnit XML reporting in v0)")
                }
                consumeRestOfStatement()
            case "withEnv":
                try expectLParen()
                let kvs = try parseListOfStrings()
                try expectRParen()
                let (innerCmds, innerArts, innerCreds) = try parseSteps()
                let prefix = kvs.map { kv -> String in
                    guard let eq = kv.firstIndex(of: "=") else { return "" }
                    let k = String(kv[..<eq])
                    let v = String(kv[kv.index(after: eq)...])
                    return "export \(k)=\(quoteForShell(v))"
                }.filter { !$0.isEmpty }
                if !prefix.isEmpty {
                    cmds.append(prefix.joined(separator: "\n"))
                }
                cmds.append(contentsOf: innerCmds)
                arts.append(contentsOf: innerArts)
                creds.append(contentsOf: innerCreds)
            case "withCredentials":
                // Phase 37: `withCredentials([string(credentialsId:
                // 'X', variable: 'Y'), ...]) { steps... }`. We parse
                // the list of bindings, then recurse into the inner
                // `{ … }` block and lift its steps + bindings into
                // this scope. Unsupported binding shapes
                // (`usernamePassword`, `sshUserPrivateKey`, etc.) are
                // dropped with a warning so the rest of the
                // pipeline still imports.
                try expectLParen()
                let bindings = try parseCredentialBindings(line: line)
                try expectRParen()
                let (innerCmds, innerArts, innerCreds) = try parseSteps()
                cmds.append(contentsOf: innerCmds)
                arts.append(contentsOf: innerArts)
                creds.append(contentsOf: bindings)
                creds.append(contentsOf: innerCreds)
            case "dir":
                try expectLParen()
                let path = try expectString()
                try expectRParen()
                let (innerCmds, innerArts, innerCreds) = try parseSteps()
                cmds.append("cd \(quoteForShell(path))")
                cmds.append(contentsOf: innerCmds)
                arts.append(contentsOf: innerArts)
                creds.append(contentsOf: innerCreds)
            case "script":
                warnings.append("line \(line): `script { … }` block ignored — scripted Groovy is not supported")
                skipBlockOrCall()
            case "stash", "unstash":
                warnings.append("line \(line): `\(s)` ignored — swiftci has no stash store; use `artifacts:` instead")
                consumeRestOfStatement()
            case "checkout":
                warnings.append("line \(line): `checkout scm` ignored — swiftci runs in a pre-cloned workspace")
                consumeRestOfStatement()
            case "input":
                warnings.append("line \(line): `input` ignored — swiftci has no interactive prompts")
                consumeRestOfStatement()
            case "timeout":
                warnings.append("line \(line): `timeout { … }` ignored (executor-level timeout)")
                skipBlockOrCall()
            case "retry":
                warnings.append("line \(line): `retry { … }` flattened — single attempt only")
                // Recurse to capture inner steps once.
                try expectLParen()
                _ = try? expectAnyArg()        // count, e.g. retry(3) { ... }
                try expectRParen()
                let (innerCmds, innerArts, innerCreds) = try parseSteps()
                cmds.append(contentsOf: innerCmds)
                arts.append(contentsOf: innerArts)
                creds.append(contentsOf: innerCreds)
            case "mail", "slackSend", "emailext", "office365ConnectorSend", "telegramSend":
                warnings.append("line \(line): plugin step `\(s)` ignored — use swiftci `notify:` instead")
                consumeRestOfStatement()
            case "httpRequest":
                let url = try parseNamedOrFirstString(name: "url")
                warnings.append("line \(line): `httpRequest` mid-build ignored. Use `notify:` post-build hook. (url=\(url ?? "?"))")
                consumeRestOfStatement()
            case "cleanWs", "deleteDir":
                cmds.append("rm -rf ./*")
                consumeRestOfStatement()
            default:
                warnings.append("line \(line): unknown step `\(s)` ignored")
                consumeRestOfStatement()
            }
            skipNewlines()
        }
        try expectRBrace()
        return (cmds, arts, creds)
    }

    // ──────────────────────────────────────────────────────────────
    // post { always { … } success { … } failure { … } }
    // ──────────────────────────────────────────────────────────────

    private mutating func parsePost() throws -> [Pipeline.Notification] {
        try expectLBrace()
        var out: [Pipeline.Notification] = []
        skipNewlines()
        while case .ident(let s, let line) = peek() {
            _ = advance()
            let when: Pipeline.Notification.When
            switch s {
            case "always", "changed", "regression", "fixed":
                when = .always
            case "success":
                when = .passed
            case "failure", "unstable", "aborted", "unsuccessful":
                when = .failed
            default:
                warnings.append("line \(line): post.\(s) condition not recognized; treating as always")
                when = .always
            }
            try expectLBrace()
            skipNewlines()
            while case .ident(let inner, let iline) = peek() {
                _ = advance()
                if inner == "httpRequest" {
                    if let url = try parseNamedOrFirstString(name: "url") {
                        out.append(Pipeline.Notification(url: url, on: when))
                    }
                    consumeRestOfStatement()
                } else {
                    warnings.append("line \(iline): post.\(s) action `\(inner)` ignored — only `httpRequest url: '…'` is translated to swiftci `notify:`")
                    consumeRestOfStatement()
                }
                skipNewlines()
            }
            try expectRBrace()
            skipNewlines()
        }
        try expectRBrace()
        return out
    }

    // ──────────────────────────────────────────────────────────────
    // environment { FOO = 'bar' BAZ = 'qux' }
    // ──────────────────────────────────────────────────────────────

    private mutating func parseEnvironment() throws -> [String: String] {
        try expectLBrace()
        var out: [String: String] = [:]
        skipNewlines()
        while case .ident(let key, let line) = peek() {
            _ = advance()
            // Expect `=`
            guard case .equals = peek() else {
                warnings.append("line \(line): malformed env entry for `\(key)` — skipping")
                consumeRestOfStatement()
                skipNewlines()
                continue
            }
            _ = advance()
            // Value is a string OR a credentials(...) call OR identifier
            if case .string(let v, _) = peek() {
                _ = advance()
                out[key] = v
            } else if case .ident(let i, _) = peek() {
                _ = advance()
                if case .lparen = peek() {
                    // Function call: credentials('x'). Drop with warning.
                    warnings.append("line \(line): env `\(key) = \(i)(...)` ignored — only literal string values are translated")
                    consumeRestOfStatement()
                } else {
                    warnings.append("line \(line): env `\(key) = \(i)` (bare identifier) ignored")
                }
            } else if case .number(let n, _) = peek() {
                _ = advance()
                out[key] = n
            } else {
                warnings.append("line \(line): env `\(key)` has unsupported value type")
                consumeRestOfStatement()
            }
            skipNewlines()
        }
        try expectRBrace()
        return out
    }

    // ──────────────────────────────────────────────────────────────
    // when { ... }  (Phase 32)
    // ──────────────────────────────────────────────────────────────

    /// Parse a stage-level `when { … }` block into a
    /// `Pipeline.StepCondition`. Supported predicates:
    ///
    ///   when { branch 'main' }
    ///   when { branch 'feature/*' }
    ///   when { environment name: 'DEPLOY', value: 'yes' }
    ///   when { not { branch 'main' } }
    ///   when { allOf { branch 'main'; environment name: 'X', value: 'Y' } }
    ///   when { anyOf { branch 'main'; branch 'release/*' } }
    ///
    /// Multiple top-level predicates are implicitly AND-ed (matches
    /// Jenkins's documented behaviour). `expression { … }`,
    /// `triggeredBy`, `tag`, `buildingTag`, `changelog`, etc. emit
    /// a warning and are dropped from the predicate.
    ///
    /// Returns `nil` if the block was empty or contained nothing
    /// translatable.
    private mutating func parseWhen(
        stageName: String,
        headerLine: Int
    ) throws -> Pipeline.StepCondition? {
        try expectLBrace()
        var collected: [Pipeline.StepCondition] = []
        skipNewlines()
        while true {
            skipNewlines()
            if case .rbrace = peek() { break }
            guard case .ident(let kw, let ln) = peek() else {
                throw JenkinsfileImporter.ParseError.unexpected(
                    line: peek().line,
                    message: "unexpected token in `when` block of stage '\(stageName)'")
            }
            _ = advance()
            if let cond = try parseWhenPredicate(
                stageName: stageName, kw: kw, line: ln
            ) {
                collected.append(cond)
            }
        }
        try expectRBrace()
        if collected.isEmpty {
            warnings.append(
                "stage '\(stageName)' (line \(headerLine)): `when` block had no translatable predicates")
            return nil
        }
        if collected.count == 1 { return collected[0] }
        return .allOf(collected)
    }

    private mutating func parseWhenPredicate(
        stageName: String,
        kw: String,
        line: Int
    ) throws -> Pipeline.StepCondition? {
        switch kw {
        case "branch":
            // branch 'main'   or   branch pattern: 'feature/*'
            // Optionally parenthesised. Handle both shapes.
            let hadParen: Bool
            if case .lparen = peek() { _ = advance(); hadParen = true }
            else { hadParen = false }
            // Skip a leading `pattern:` or `name:` named arg if present.
            if case .ident(let id, _) = peek(),
               id == "pattern" || id == "name"
            {
                _ = advance()
                if case .colon = peek() { _ = advance() }
            }
            let pat = try expectString()
            // Drop any trailing `, comparator: '…'` etc.
            skipUntilLineEndOrCloseParen()
            if hadParen, case .rparen = peek() { _ = advance() }
            return .branch(pat)

        case "environment":
            // environment name: 'X', value: 'Y'
            let hadParen: Bool
            if case .lparen = peek() { _ = advance(); hadParen = true }
            else { hadParen = false }
            var name: String? = nil
            var value: String? = nil
            for _ in 0..<2 {
                guard case .ident(let key, _) = peek() else { break }
                _ = advance()
                if case .colon = peek() { _ = advance() }
                let v = try expectString()
                if key == "name"  { name  = v }
                if key == "value" { value = v }
                if case .comma = peek() { _ = advance() }
            }
            skipUntilLineEndOrCloseParen()
            if hadParen, case .rparen = peek() { _ = advance() }
            guard let n = name, let v = value else {
                warnings.append(
                    "stage '\(stageName)' (line \(line)): `when { environment }` missing name or value; dropped")
                return nil
            }
            return .environment(name: n, value: v)

        case "not":
            try expectLBrace()
            skipNewlines()
            guard case .ident(let inner, let iln) = peek() else {
                throw JenkinsfileImporter.ParseError.unexpected(
                    line: peek().line,
                    message: "expected predicate inside `not { }` of stage '\(stageName)'")
            }
            _ = advance()
            let innerCond = try parseWhenPredicate(
                stageName: stageName, kw: inner, line: iln)
            skipNewlines()
            try expectRBrace()
            guard let c = innerCond else { return nil }
            return .not(c)

        case "allOf", "anyOf":
            try expectLBrace()
            var inner: [Pipeline.StepCondition] = []
            skipNewlines()
            while case .ident(let id, let ln) = peek() {
                _ = advance()
                if let c = try parseWhenPredicate(
                    stageName: stageName, kw: id, line: ln
                ) {
                    inner.append(c)
                }
                skipNewlines()
            }
            try expectRBrace()
            if inner.isEmpty {
                warnings.append(
                    "stage '\(stageName)' (line \(line)): `\(kw)` had no translatable predicates")
                return nil
            }
            return kw == "allOf" ? .allOf(inner) : .anyOf(inner)

        case "expression":
            warnings.append(
                "stage '\(stageName)' (line \(line)): `when { expression { … } }` not translated — swiftci does not run Groovy; dropped")
            skipBlockOrCall()
            return nil

        default:
            warnings.append(
                "stage '\(stageName)' (line \(line)): `when { \(kw) }` not translated; dropped")
            skipBlockOrCall()
            return nil
        }
    }

    /// Consumes tokens up to (but not including) the next newline or
    /// `)`, used to drop unrecognised trailing named-arguments on a
    /// when-predicate without bailing out of the surrounding parse.
    private mutating func skipUntilLineEndOrCloseParen() {
        while true {
            switch peek() {
            case .newline, .rparen, .rbrace, .eof:
                return
            default:
                _ = advance()
            }
        }
    }

    // ──────────────────────────────────────────────────────────────
    // parameters { string(name: 'X', defaultValue: 'Y') ... }  (Phase 24)
    // ──────────────────────────────────────────────────────────────

    /// Returns `parameter-name : default-value-as-string`. Recognises
    /// `string`, `booleanParam`, `choice`. Anything else is dropped
    /// with a warning. Caller has already consumed the `parameters`
    /// keyword and is sitting on the opening `{`.
    private mutating func parseParameters() throws -> [String: String] {
        try expectLBrace()
        var out: [String: String] = [:]
        skipNewlines()
        while case .ident(let kind, let line) = peek() {
            _ = advance()
            switch kind {
            case "string":
                if let (n, v) = try parseSimpleParam(stringValueOnly: true, line: line) {
                    out[n] = v ?? ""
                }
            case "booleanParam":
                if let (n, v) = try parseSimpleParam(stringValueOnly: false, line: line) {
                    out[n] = v ?? "false"
                }
            case "choice":
                if let (n, choices) = try parseChoiceParam(line: line) {
                    out[n] = choices.first ?? ""
                }
            default:
                warnings.append(
                    "line \(line): parameter kind `\(kind)` not translated; ignoring")
                skipBlockOrCall()
            }
            skipNewlines()
        }
        try expectRBrace()
        return out
    }

    /// Parse `kind(name: 'X', defaultValue: <literal>)`. When
    /// `stringValueOnly` is true, only string literals are accepted
    /// as defaults; otherwise bare identifiers (`true`, `false`) and
    /// numbers are accepted and stringified verbatim.
    private mutating func parseSimpleParam(
        stringValueOnly: Bool, line: Int
    ) throws -> (String, String?)? {
        try expectLParen()
        var name: String? = nil
        var value: String? = nil
        while !isRParen(peek()) && !isEOF(peek()) {
            if case .ident(let k, _) = peek(),
               tokens.indices.contains(pos + 1),
               case .colon = tokens[pos + 1] {
                _ = advance(); _ = advance()       // ident :
                switch peek() {
                case .string(let s, _):
                    _ = advance()
                    if k == "name" { name = s }
                    else if k == "defaultValue" { value = s }
                case .ident(let i, _):
                    _ = advance()
                    if !stringValueOnly, k == "defaultValue" {
                        value = i
                    }
                case .number(let n, _):
                    _ = advance()
                    if !stringValueOnly, k == "defaultValue" {
                        value = n
                    }
                default:
                    skipExpression()
                }
            } else {
                skipExpression()
            }
            if case .comma = peek() { _ = advance() }
            skipNewlines()
        }
        try expectRParen()
        guard let name, !name.isEmpty else {
            warnings.append("line \(line): parameter is missing `name:` — dropping")
            return nil
        }
        return (name, value)
    }

    /// Parse `choice(name: 'X', choices: ['a','b','c'])` or the
    /// equivalent newline-separated string form
    /// `choices: 'a\nb\nc'`.
    private mutating func parseChoiceParam(line: Int) throws -> (String, [String])? {
        try expectLParen()
        var name: String? = nil
        var choices: [String] = []
        while !isRParen(peek()) && !isEOF(peek()) {
            if case .ident(let k, _) = peek(),
               tokens.indices.contains(pos + 1),
               case .colon = tokens[pos + 1] {
                _ = advance(); _ = advance()
                switch peek() {
                case .string(let s, _):
                    _ = advance()
                    if k == "name" { name = s }
                    else if k == "choices" {
                        choices = s.split(separator: "\n").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                    }
                case .lbracket:
                    _ = advance()
                    if k == "choices" {
                        while !isRBracket(peek()) && !isEOF(peek()) {
                            if case .string(let s, _) = peek() {
                                _ = advance()
                                choices.append(s)
                            } else {
                                skipExpression()
                            }
                            if case .comma = peek() { _ = advance() }
                            skipNewlines()
                        }
                        if case .rbracket = peek() { _ = advance() }
                    } else {
                        var depth = 1
                        while depth > 0 && !isEOF(peek()) {
                            if case .lbracket = peek() { depth += 1 }
                            else if case .rbracket = peek() { depth -= 1 }
                            _ = advance()
                        }
                    }
                default:
                    skipExpression()
                }
            } else {
                skipExpression()
            }
            if case .comma = peek() { _ = advance() }
            skipNewlines()
        }
        try expectRParen()
        guard let name, !name.isEmpty else {
            warnings.append("line \(line): choice parameter missing `name:` — dropping")
            return nil
        }
        return (name, choices)
    }

    // ──────────────────────────────────────────────────────────────
    // Argument helpers
    // ──────────────────────────────────────────────────────────────

    /// `sh 'cmd'`, `sh "cmd"`, `sh script: 'cmd'`, `sh(script: 'cmd', returnStdout: true)`.
    private mutating func parseShStyle() throws -> String {
        if case .lparen = peek() {
            _ = advance()
            // Could be a named-args call: sh(script: '…', label: '…')
            var cmd: String? = nil
            while !isRParen(peek()) && !isEOF(peek()) {
                if case .ident(let k, _) = peek(),
                   tokens.indices.contains(pos + 1),
                   case .colon = tokens[pos + 1] {
                    _ = advance()         // ident
                    _ = advance()         // :
                    if case .string(let v, _) = peek() {
                        _ = advance()
                        if k == "script" { cmd = v }
                    } else {
                        // Skip non-string value.
                        skipExpression()
                    }
                } else if case .string(let v, _) = peek() {
                    // Bare positional first arg is the script.
                    _ = advance()
                    cmd = cmd ?? v
                } else {
                    skipExpression()
                }
                if case .comma = peek() { _ = advance() }
                skipNewlines()
            }
            try expectRParen()
            return cmd ?? ""
        }
        if case .string(let s, _) = peek() {
            _ = advance()
            return s
        }
        warnings.append("line \(peek().line): expected string after `sh`/`bat`/`pwsh`")
        return ""
    }

    private mutating func parseFirstStringArg() throws -> String? {
        if case .lparen = peek() {
            _ = advance()
            var first: String? = nil
            while !isRParen(peek()) && !isEOF(peek()) {
                if case .string(let v, _) = peek() {
                    _ = advance()
                    first = first ?? v
                } else if case .ident = peek(),
                          tokens.indices.contains(pos + 1),
                          case .colon = tokens[pos + 1] {
                    // Skip named args
                    _ = advance(); _ = advance()
                    skipExpression()
                } else {
                    skipExpression()
                }
                if case .comma = peek() { _ = advance() }
                skipNewlines()
            }
            try expectRParen()
            return first
        }
        if case .string(let s, _) = peek() {
            _ = advance()
            return s
        }
        return nil
    }

    /// Parse `step name: 'value'` or `step 'value'` and return the value
    /// matching `name`, otherwise the first string argument seen.
    private mutating func parseNamedOrFirstString(name: String) throws -> String? {
        if case .lparen = peek() {
            _ = advance()
            var match: String? = nil
            var first: String? = nil
            while !isRParen(peek()) && !isEOF(peek()) {
                if case .ident(let k, _) = peek(),
                   tokens.indices.contains(pos + 1),
                   case .colon = tokens[pos + 1] {
                    _ = advance(); _ = advance()
                    if case .string(let v, _) = peek() {
                        _ = advance()
                        if k == name { match = v }
                        first = first ?? v
                    } else {
                        skipExpression()
                    }
                } else if case .string(let v, _) = peek() {
                    _ = advance()
                    first = first ?? v
                } else {
                    skipExpression()
                }
                if case .comma = peek() { _ = advance() }
                skipNewlines()
            }
            try expectRParen()
            return match ?? first
        }
        // Statement-form: `step name: 'v'` (no parens)
        if case .ident(let k, _) = peek(),
           tokens.indices.contains(pos + 1),
           case .colon = tokens[pos + 1] {
            _ = advance(); _ = advance()
            if case .string(let v, _) = peek() {
                _ = advance()
                if k == name { return v } else { return v }
            }
        }
        if case .string(let s, _) = peek() {
            _ = advance()
            return s
        }
        return nil
    }

    /// `["K=V", "K2=V2"]` → ["K=V", "K2=V2"]
    private mutating func parseListOfStrings() throws -> [String] {
        try expectLBracket()
        var out: [String] = []
        while !isRBracket(peek()) && !isEOF(peek()) {
            if case .string(let v, _) = peek() {
                _ = advance()
                out.append(v)
            } else {
                skipExpression()
            }
            if case .comma = peek() { _ = advance() }
            skipNewlines()
        }
        try expectRBracket()
        return out
    }

    /// Phase 37: parse a Jenkins `withCredentials([…])` argument
    /// list. Recognised entries:
    ///
    ///     string(credentialsId: 'X', variable: 'Y')
    ///
    /// Unsupported variants (`usernamePassword(...)`,
    /// `sshUserPrivateKey(...)`, `file(...)`, `certificate(...)`)
    /// are skipped with a warning so the rest of the pipeline still
    /// imports. The caller is responsible for already having consumed
    /// the opening `(` and is responsible for consuming the closing
    /// `)`. Inside, we expect a `[ … ]` list.
    private mutating func parseCredentialBindings(line: Int) throws
        -> [Pipeline.CredentialBinding]
    {
        try expectLBracket()
        var out: [Pipeline.CredentialBinding] = []
        while !isRBracket(peek()) && !isEOF(peek()) {
            skipNewlines()
            guard case .ident(let kind, _) = peek() else {
                skipExpression()
                if case .comma = peek() { _ = advance() }
                continue
            }
            _ = advance()
            switch kind {
            case "string":
                try expectLParen()
                var credID: String? = nil
                var variable: String? = nil
                // Parse zero or more `name: 'value'` pairs.
                while !isRParen(peek()) && !isEOF(peek()) {
                    if case .ident(let argName, _) = peek() {
                        _ = advance()
                        if case .colon = peek() { _ = advance() }
                        if case .string(let v, _) = peek() {
                            _ = advance()
                            switch argName {
                            case "credentialsId": credID = v
                            case "variable":      variable = v
                            default: break
                            }
                        } else {
                            skipExpression()
                        }
                    } else {
                        skipExpression()
                    }
                    if case .comma = peek() { _ = advance() }
                    skipNewlines()
                }
                try expectRParen()
                if let id = credID, let v = variable {
                    out.append(Pipeline.CredentialBinding(
                        credentialsId: id, variable: v))
                } else {
                    warnings.append("line \(line): `string(...)` binding missing credentialsId/variable — skipped")
                }
            case "usernamePassword", "sshUserPrivateKey", "file",
                 "certificate", "gitUsernamePassword":
                warnings.append("line \(line): `\(kind)(...)` credential binding ignored — only `string(...)` is supported in swiftci v1")
                if case .lparen = peek() {
                    skipBalanced(open: .lparen(0), close: .rparen(0))
                }
            default:
                warnings.append("line \(line): unknown credential binding `\(kind)` ignored")
                if case .lparen = peek() {
                    skipBalanced(open: .lparen(0), close: .rparen(0))
                }
            }
            if case .comma = peek() { _ = advance() }
            skipNewlines()
        }
        try expectRBracket()
        return out
    }

    // ──────────────────────────────────────────────────────────────
    // Skipping helpers
    // ──────────────────────────────────────────────────────────────

    /// `agent any`, `agent none`, `agent { label 'foo' }`.
    private mutating func skipAgent() {
        if case .ident = peek() {
            _ = advance()
            return
        }
        skipBlockOrCall()
    }

    /// After consuming an identifier, swallow either:
    /// - a parenthesised arg list and optional block,
    /// - a brace block,
    /// - or just the rest of the statement.
    private mutating func skipBlockOrCall() {
        if case .lparen = peek() { skipBalanced(open: .lparen(0), close: .rparen(0)) }
        if case .lbrace = peek() { skipBalanced(open: .lbrace(0), close: .rbrace(0)) }
        // Tolerate trailing tokens until newline.
        while !isEOF(peek()) {
            switch peek() {
            case .newline, .rbrace: return
            default: _ = advance()
            }
        }
    }

    /// After consuming a step identifier in a `steps {}` block, drop
    /// every remaining token on this logical line. Used for unrecognised
    /// or partially-translated steps.
    private mutating func consumeRestOfStatement() {
        var depth = 0
        while !isEOF(peek()) {
            switch peek() {
            case .lparen, .lbrace, .lbracket:
                depth += 1; _ = advance()
            case .rparen, .rbracket:
                if depth == 0 { return }
                depth -= 1; _ = advance()
            case .rbrace:
                if depth == 0 { return }
                depth -= 1; _ = advance()
            case .newline:
                if depth == 0 { return }
                _ = advance()
            default:
                _ = advance()
            }
        }
    }

    private mutating func skipExpression() {
        var depth = 0
        while !isEOF(peek()) {
            switch peek() {
            case .lparen, .lbrace, .lbracket:
                depth += 1; _ = advance()
            case .rparen, .rbracket, .rbrace:
                if depth == 0 { return }
                depth -= 1; _ = advance()
            case .comma where depth == 0:
                return
            case .newline where depth == 0:
                return
            default:
                _ = advance()
            }
        }
    }

    private mutating func skipBalanced(open: Token, close: Token) {
        // Open is at current pos.
        let isOpen: (Token) -> Bool = { tok in
            switch (tok, open) {
            case (.lparen, .lparen), (.lbrace, .lbrace), (.lbracket, .lbracket): return true
            default: return false
            }
        }
        let isClose: (Token) -> Bool = { tok in
            switch (tok, close) {
            case (.rparen, .rparen), (.rbrace, .rbrace), (.rbracket, .rbracket): return true
            default: return false
            }
        }
        guard isOpen(peek()) else { return }
        var depth = 0
        repeat {
            let t = advance()
            if isOpen(t) { depth += 1 }
            if isClose(t) { depth -= 1 }
            if depth == 0 { return }
        } while !isEOF(peek())
    }

    // ──────────────────────────────────────────────────────────────
    // Primitives
    // ──────────────────────────────────────────────────────────────

    private func peek() -> Token { tokens[pos] }

    @discardableResult
    private mutating func advance() -> Token {
        let t = tokens[pos]
        if pos + 1 < tokens.count { pos += 1 }
        return t
    }

    private mutating func skipNewlines() {
        while case .newline = peek() { _ = advance() }
    }

    private mutating func expectLBrace() throws {
        skipNewlines()
        guard case .lbrace = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected `{`")
        }
        _ = advance()
        skipNewlines()
    }

    private mutating func expectRBrace() throws {
        skipNewlines()
        guard case .rbrace = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected `}`")
        }
        _ = advance()
    }

    private mutating func expectLParen() throws {
        skipNewlines()
        guard case .lparen = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected `(`")
        }
        _ = advance()
        skipNewlines()
    }

    private mutating func expectRParen() throws {
        skipNewlines()
        guard case .rparen = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected `)`")
        }
        _ = advance()
    }

    private mutating func expectLBracket() throws {
        skipNewlines()
        guard case .lbracket = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected `[`")
        }
        _ = advance()
        skipNewlines()
    }

    private mutating func expectRBracket() throws {
        skipNewlines()
        guard case .rbracket = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected `]`")
        }
        _ = advance()
    }

    private mutating func expectString() throws -> String {
        skipNewlines()
        guard case .string(let s, _) = peek() else {
            throw JenkinsfileImporter.ParseError.unexpected(
                line: peek().line, message: "expected string")
        }
        _ = advance()
        return s
    }

    private mutating func expectAnyArg() throws -> Token {
        skipNewlines()
        return advance()
    }

    private func isRParen(_ t: Token) -> Bool {
        if case .rparen = t { return true } else { return false }
    }
    private func isRBracket(_ t: Token) -> Bool {
        if case .rbracket = t { return true } else { return false }
    }
    private func isEOF(_ t: Token) -> Bool {
        if case .eof = t { return true } else { return false }
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Shell quoting
// ────────────────────────────────────────────────────────────────────

/// Single-quote `s` for POSIX shells. Embedded single-quotes are
/// closed, escaped, and re-opened: `'it'\''s'`.
private func quoteForShell(_ s: String) -> String {
    if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "/" || $0 == "." || $0 == "-" || $0 == "@" || $0 == "=" }) && !s.isEmpty {
        return s
    }
    let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}
