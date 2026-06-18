import Foundation

/// Phase 34: clone a git repository into a build's workspace and load
/// the pipeline definition from a Jenkinsfile inside it. Used by
/// `BuildExecutor.runBuild` when `pipeline.scm` is non-nil.
///
/// Implementation notes
/// --------------------
/// - Shells out to the host's `git` binary. We do not bundle libgit2.
///   The error path explains the missing prerequisite to the operator.
/// - The clone target MUST be empty; the executor wipes the workspace
///   right before invoking us, so this holds in practice.
/// - Output (stdout + stderr merged) is returned to the caller as a
///   single UTF-8 string so the executor can append it to the build
///   log under a clearly-marked banner.
/// - Cross-platform: `git` resolves through PATH on macOS/Linux/Windows.
public enum SCMCheckout {

    /// Result of a successful checkout + pipeline parse.
    public struct Result: Sendable {
        public let pipeline: Pipeline
        /// Combined `git clone` + `git checkout` output, ready to log.
        public let log: String
        /// Warnings emitted by the Jenkinsfile importer.
        public let warnings: [String]
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case gitNotFound
        case cloneFailed(exitCode: Int32, output: String)
        case checkoutFailed(ref: String, exitCode: Int32, output: String)
        case jenkinsfileMissing(path: String)
        case jenkinsfileNotUTF8(path: String)
        case parseFailed(underlying: String)

        public var description: String {
            switch self {
            case .gitNotFound:
                return "scm: `git` not found on PATH"
            case .cloneFailed(let code, let out):
                return "scm: git clone failed (exit \(code))\n\(out)"
            case .checkoutFailed(let ref, let code, let out):
                return "scm: git checkout '\(ref)' failed (exit \(code))\n\(out)"
            case .jenkinsfileMissing(let path):
                return "scm: jenkinsfile not found at \(path)"
            case .jenkinsfileNotUTF8(let path):
                return "scm: jenkinsfile at \(path) is not valid UTF-8"
            case .parseFailed(let u):
                return "scm: jenkinsfile parse failed: \(u)"
            }
        }
    }

    /// Clone `scm.git.url` at `scm.git.ref` into `workspace`, parse
    /// `<workspace>/<scm.jenkinsfile>` via `JenkinsfileImporter`, and
    /// return a synthesized `Pipeline` whose top-level fields
    /// (`name`, `notify`, `retention`, `triggers`, `agentLabels`,
    /// `scm`) come from `original` and whose `steps` come from the
    /// imported Jenkinsfile.
    public static func checkoutAndLoad(
        scm: Pipeline.SCMConfig,
        original: Pipeline,
        workspace: URL
    ) throws -> Result {
        var combinedLog = ""

        // 1. git clone <url> .
        let cloneOut = try run(
            "git",
            args: ["clone", "--no-tags", scm.git.url, "."],
            cwd: workspace)
        combinedLog += "$ git clone --no-tags \(scm.git.url) .\n"
        combinedLog += cloneOut.output
        if !cloneOut.output.hasSuffix("\n") { combinedLog += "\n" }
        if cloneOut.exit != 0 {
            throw Error.cloneFailed(exitCode: cloneOut.exit, output: cloneOut.output)
        }

        // 2. git -c advice.detachedHead=false checkout <ref>
        let coOut = try run(
            "git",
            args: ["-c", "advice.detachedHead=false", "checkout", scm.git.ref],
            cwd: workspace)
        combinedLog += "$ git -c advice.detachedHead=false checkout \(scm.git.ref)\n"
        combinedLog += coOut.output
        if !coOut.output.hasSuffix("\n") { combinedLog += "\n" }
        if coOut.exit != 0 {
            throw Error.checkoutFailed(
                ref: scm.git.ref, exitCode: coOut.exit, output: coOut.output)
        }

        // 3. Read Jenkinsfile.
        let jfURL = workspace.appendingPathComponent(scm.jenkinsfile)
        guard FileManager.default.fileExists(atPath: jfURL.path) else {
            throw Error.jenkinsfileMissing(path: jfURL.path)
        }
        let jfData = try Data(contentsOf: jfURL)
        guard let jfText = String(data: jfData, encoding: .utf8) else {
            throw Error.jenkinsfileNotUTF8(path: jfURL.path)
        }

        // 4. Parse via JenkinsfileImporter.
        let parsed: JenkinsfileImporter.Result
        do {
            parsed = try JenkinsfileImporter.parse(jfText, defaultName: original.name)
        } catch {
            throw Error.parseFailed(underlying: String(describing: error))
        }

        // 5. Splice imported steps into a Pipeline that preserves the
        //    controller-side fields. Setting `scm: original.scm` keeps
        //    the audit trail visible on rerun.
        let effective = Pipeline(
            name: original.name,
            steps: parsed.pipeline.steps,
            notify: original.notify,
            retention: original.retention,
            triggers: original.triggers,
            agentLabels: original.agentLabels,
            scm: original.scm
        )
        return Result(pipeline: effective, log: combinedLog, warnings: parsed.warnings)
    }

    // ──────────────────────────────────────────────────────────────
    // private — sync `Process` runner
    // ──────────────────────────────────────────────────────────────

    private struct ProcOut {
        let exit: Int32
        let output: String
    }

    private static func run(
        _ tool: String, args: [String], cwd: URL
    ) throws -> ProcOut {
        guard let exeURL = resolveOnPath(tool) else {
            throw Error.gitNotFound
        }
        let p = Foundation.Process()
        p.executableURL = exeURL
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)
            ?? "(\(data.count) bytes of non-UTF-8 output)"
        return ProcOut(exit: p.terminationStatus, output: out)
    }

    private static func resolveOnPath(_ tool: String) -> URL? {
        #if os(Windows)
        let candidates = [tool, tool + ".exe"]
        let sep: Character = ";"
        #else
        let candidates = [tool]
        let sep: Character = ":"
        #endif
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"]
                ?? ProcessInfo.processInfo.environment["Path"] else {
            return nil
        }
        for dir in pathEnv.split(separator: sep) {
            for c in candidates {
                let candidate = URL(fileURLWithPath: String(dir))
                    .appendingPathComponent(c)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
