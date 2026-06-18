import Foundation

extension JobStore {
    // ──────────────────────────────────────────────────────────────────
    // Build paths
    // ──────────────────────────────────────────────────────────────────

    /// `<root>/jobs/<jobID>/builds/`
    internal func buildsDir(jobID: String) -> URL {
        jobDir(for: jobID).appendingPathComponent("builds", isDirectory: true)
    }

    /// `<root>/jobs/<jobID>/builds/<number>/`
    internal func buildDir(jobID: String, number: Int) -> URL {
        buildsDir(jobID: jobID).appendingPathComponent(String(number), isDirectory: true)
    }

    private func statusURL(jobID: String, number: Int) -> URL {
        buildDir(jobID: jobID, number: number).appendingPathComponent("status.json")
    }

    private func logURL(jobID: String, number: Int) -> URL {
        buildDir(jobID: jobID, number: number).appendingPathComponent("log.txt")
    }

    /// `<root>/jobs/<jobID>/builds/<number>/workspace/` — the CWD
    /// every step in this build runs in. Wiped + recreated on each
    /// `provisionWorkspace` call.
    internal func workspaceURL(jobID: String, number: Int) -> URL {
        buildDir(jobID: jobID, number: number).appendingPathComponent("workspace", isDirectory: true)
    }

    /// `<root>/jobs/<jobID>/builds/<number>/webhook.json` — the
    /// captured webhook payload (headers + body) for builds triggered
    /// via `POST /webhook/:id`. Exposed to steps as
    /// `SWIFTCI_WEBHOOK_BODY_PATH`.
    internal func webhookPayloadURL(jobID: String, number: Int) -> URL {
        buildDir(jobID: jobID, number: number).appendingPathComponent("webhook.json")
    }

    /// `<root>/jobs/<jobID>/builds/<number>/artifacts/` — collected
    /// artifact files (or directories, copied recursively from the
    /// workspace) after each successful step. Flat naming: `name`
    /// inside the dir is `basename(originalRelativePath)`.
    internal func artifactsDir(jobID: String, number: Int) -> URL {
        buildDir(jobID: jobID, number: number).appendingPathComponent("artifacts", isDirectory: true)
    }

    // ──────────────────────────────────────────────────────────────────
    // Build CRUD
    // ──────────────────────────────────────────────────────────────────

    /// Reserve the next build number for `jobID` and persist an initial
    /// `Build` with status `.queued`. Returns the new `Build` (its
    /// `.number` is the assigned value).
    ///
    /// The job must already exist — call `loadJob(id:)` first to check
    /// 404s.
    ///
    /// This method is NOT safe to call concurrently with itself for the
    /// same `jobID`; serialize through `BuildExecutor.enqueue(...)`.
    public func createBuild(jobID: String) throws -> Build {
        let bDir = buildsDir(jobID: jobID)
        guard FileManager.default.fileExists(atPath: jobDir(for: jobID).path) else {
            throw JobStoreError.noSuchJob(jobID)
        }
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)

        // Next number = (max existing) + 1, starting at 1.
        let existing = try listBuildNumbers(jobID: jobID)
        let next = (existing.max() ?? 0) + 1

        let buildDir = buildDir(jobID: jobID, number: next)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: false)

        let build = Build(jobID: jobID, number: next, status: .queued,
                          queuedAt: Date())
        try writeStatus(build)
        // Pre-create empty log file so readers don't have to special-case.
        FileManager.default.createFile(atPath: logURL(jobID: jobID, number: next).path, contents: nil)
        return build
    }

    /// Load a previously-created build. Returns nil if neither the
    /// build directory nor its `status.json` exists.
    public func loadBuild(jobID: String, number: Int) throws -> Build? {
        let url = statusURL(jobID: jobID, number: number)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.statusDecoder.decode(Build.self, from: data)
    }

    /// List all known build numbers for `jobID`, ascending.
    public func listBuildNumbers(jobID: String) throws -> [Int] {
        let bDir = buildsDir(jobID: jobID)
        guard FileManager.default.fileExists(atPath: bDir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: bDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { Int($0.lastPathComponent) }
            .sorted()
    }

    /// Overwrite `status.json` for the build identified by
    /// `build.jobID` + `build.number`. Atomic — writes to a sibling
    /// `.tmp` file and renames.
    public func updateBuild(_ build: Build) throws {
        try writeStatus(build)
    }

    // ──────────────────────────────────────────────────────────────────
    // Log I/O
    // ──────────────────────────────────────────────────────────────────

    /// Append `text` to the build's `log.txt`. The text is written as
    /// UTF-8 bytes verbatim; callers append their own newlines.
    public func appendLog(jobID: String, number: Int, _ text: String) throws {
        let url = logURL(jobID: jobID, number: number)
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            // File didn't exist for some reason; create it.
            try data.write(to: url)
        }
    }

    /// Read the build's `log.txt`. If `tail` is non-nil, return only the
    /// last `tail` lines (after splitting on `\n`).
    ///
    /// A trailing newline at the end of the file produces an empty
    /// subsequence in the split, which would otherwise eat one slot of
    /// `tail`. We drop it before taking the suffix, then re-append a
    /// trailing newline so the returned string is still well-formed.
    public func readLog(jobID: String, number: Int, tail: Int? = nil) throws -> String {
        let url = logURL(jobID: jobID, number: number)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let full = try AtomicIO.readString(from: url)
        guard let tail else { return full }
        var lines = full.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        if lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count <= tail { return full }
        return lines.suffix(tail).joined(separator: "\n") + "\n"
    }

    // ──────────────────────────────────────────────────────────────────
    // Internals
    // ──────────────────────────────────────────────────────────────────

    private static let statusEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let statusDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func writeStatus(_ build: Build) throws {
        let url = statusURL(jobID: build.jobID, number: build.number)
        let data = try Self.statusEncoder.encode(build)
        try AtomicIO.writeData(data, to: url)
    }

    // ──────────────────────────────────────────────────────────────────
    // Workspace + webhook payload (Phase 6)
    // ──────────────────────────────────────────────────────────────────

    /// Create (or wipe + recreate) the workspace directory for a build
    /// and return its URL. The build directory itself is left alone
    /// so `status.json`, `log.txt`, and `webhook.json` survive.
    public func provisionWorkspace(jobID: String, number: Int) throws -> URL {
        let url = workspaceURL(jobID: jobID, number: number)
        try AtomicIO.withRetry(attempts: 8) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Write the captured webhook payload to `webhook.json` for the
    /// build. Atomic, with the same Windows-AV retry as everything
    /// else.
    public func writeWebhookPayload(
        jobID: String, number: Int, payload: WebhookPayload
    ) throws {
        let url = webhookPayloadURL(jobID: jobID, number: number)
        let data = try Self.statusEncoder.encode(payload)
        try AtomicIO.writeData(data, to: url)
    }

    /// Load the captured webhook payload if one was persisted; returns
    /// nil otherwise.
    public func loadWebhookPayload(jobID: String, number: Int) throws -> WebhookPayload? {
        let url = webhookPayloadURL(jobID: jobID, number: number)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try AtomicIO.readString(from: url)
        let data = Data(raw.utf8)
        return try Self.statusDecoder.decode(WebhookPayload.self, from: data)
    }

    // ──────────────────────────────────────────────────────────────────
    // Artifacts (Phase 7)
    // ──────────────────────────────────────────────────────────────────

    /// Copy a workspace-relative path into the build's artifacts dir.
    ///
    /// `relativePath` is interpreted relative to the build's workspace
    /// (`<build>/workspace/`). Both files and directories are
    /// supported; directories are copied recursively. The destination
    /// name is `basename(relativePath)` — artifact namespacing is flat
    /// (matches the v0 surface area). Returns the absolute URL of the
    /// copied artifact.
    ///
    /// Path-traversal protection: any path that resolves outside the
    /// workspace (e.g. `../etc/passwd`, absolute paths) is rejected
    /// with `ArtifactError.pathOutsideWorkspace`. Missing sources
    /// throw `ArtifactError.missing`.
    @discardableResult
    public func collectArtifact(
        jobID: String,
        number: Int,
        relativePath: String
    ) throws -> URL {
        let workspace = workspaceURL(jobID: jobID, number: number)
        let candidate = workspace.appendingPathComponent(relativePath)
        let wsPath = Self.canonicalPath(workspace.path)
        let candPath = Self.canonicalPath(candidate.path)
        guard Self.isPathInside(candPath, workspacePath: wsPath) else {
            throw ArtifactError.pathOutsideWorkspace(relativePath)
        }
        guard FileManager.default.fileExists(atPath: candPath) else {
            throw ArtifactError.missing(relativePath)
        }

        let dest = artifactsDir(jobID: jobID, number: number)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        // Flat naming; if the relative path includes subdirs, only its
        // basename survives. Subsequent collections with the same
        // basename overwrite the earlier one — matches Jenkins.
        let name = candidate.lastPathComponent
        let destURL = dest.appendingPathComponent(name)
        try AtomicIO.withRetry(attempts: 8) {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: candPath), to: destURL)
        }
        return destURL
    }

    /// List the names of artifacts collected for a build. Returns
    /// lexicographically sorted basenames (the same naming used by
    /// `collectArtifact`).
    public func listArtifacts(jobID: String, number: Int) throws -> [String] {
        let dir = artifactsDir(jobID: jobID, number: number)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.map { $0.lastPathComponent }.sorted()
    }

    /// Resolve a named artifact to an on-disk URL. Returns nil if the
    /// artifact doesn't exist or its resolved path escapes the
    /// build's artifacts dir (defence-in-depth against weird names).
    public func artifactURL(
        jobID: String, number: Int, name: String
    ) -> URL? {
        let root = artifactsDir(jobID: jobID, number: number)
        let candidate = root.appendingPathComponent(name)
        let rootPath = Self.canonicalPath(root.path)
        let candPath = Self.canonicalPath(candidate.path)
        // Reject if candidate IS the root, or escapes outside.
        guard candPath != rootPath,
              Self.isPathInside(candPath, workspacePath: rootPath) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: candPath) else { return nil }
        return URL(fileURLWithPath: candPath)
    }

    /// Write a raw artifact byte payload into the build's artifacts
    /// dir. Used by the controller when a `swiftci-agent` streams
    /// `AgentMessage.artifact` frames back over the WebSocket — the
    /// agent has already validated and read the file off its own
    /// workspace, so on the controller side we only need to guard
    /// against malicious `name` values (no `/`, no `\`, no `..`, no
    /// drive letters, no leading dots).
    ///
    /// Returns the absolute URL of the persisted artifact. Throws
    /// `ArtifactError.invalidName` if `name` is rejected.
    @discardableResult
    public func writeAgentArtifact(
        jobID: String,
        number: Int,
        name: String,
        data: Data
    ) throws -> URL {
        guard Self.isSafeArtifactName(name) else {
            throw ArtifactError.invalidName(name)
        }
        let dest = artifactsDir(jobID: jobID, number: number)
        try FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true)
        let destURL = dest.appendingPathComponent(name)
        try AtomicIO.withRetry(attempts: 8) {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try data.write(to: destURL)
        }
        return destURL
    }

    /// Reject obviously-dangerous artifact names from agents.
    /// Allowed: ASCII letters, digits, `_`, `-`, `.`, single dot
    /// extensions like `out.txt`. Rejected: any path separator, any
    /// `..` segment, any leading dot or whitespace, empty string,
    /// anything longer than 200 bytes (filesystem-friendly cap).
    static func isSafeArtifactName(_ name: String) -> Bool {
        if name.isEmpty || name.count > 200 { return false }
        if name.hasPrefix(".") || name.hasPrefix(" ") { return false }
        if name.contains("..") { return false }
        for ch in name {
            switch ch {
            case "/", "\\", ":", "*", "?", "\"", "<", ">", "|":
                return false
            case "\0"..."\u{1F}":
                return false
            default:
                continue
            }
        }
        return true
    }

    /// Canonicalize a filesystem path string for prefix comparison.
    ///
    /// Lexical only: no realpath, no symlink resolution, no 8.3
    /// short-name expansion. Flattens `.` / `..` segments, normalizes
    /// separators to platform-native, and drops trailing separators.
    /// This is sufficient because every caller builds both sides of
    /// the comparison from the same `workspaceURL(...)`, so they
    /// share the same prefix verbatim regardless of how the host OS
    /// would `realpath` them.
    ///
    /// Avoiding `URL.standardizedFileURL` is intentional: in Swift
    /// 6.x on Windows, `URL.appendingPathComponent` can interleave
    /// `/` separators inside an otherwise `\`-separated path, and
    /// `standardizedFileURL.path` does NOT normalize them back to a
    /// single separator style — so the parent URL's `.path` ends up
    /// `C:\...\workspace` while the child's `.path` is
    /// `C:\...\workspace/hello.txt`, breaking prefix comparison.
    private static func canonicalPath(_ raw: String) -> String {
        #if os(Windows)
        let sep = Character("\\")
        // Treat both `\` and `/` as separators on Windows so URL-
        // composed paths normalize to a single style.
        let unified = raw.replacingOccurrences(of: "/", with: "\\")
        #else
        let sep = Character("/")
        let unified = raw
        #endif

        // Walk components, applying `.`/`..` semantics.
        let components = unified.split(separator: sep, omittingEmptySubsequences: false)
        var stack: [Substring] = []
        // Preserve leading drive (`C:`) or leading separator semantics
        // by recording whether the path is absolute.
        let isAbsolute: Bool
        var startIndex = 0
        #if os(Windows)
        // Windows absolute looks like `C:` (drive-relative-cwd is
        // rare); take the drive + leading-empty (== leading `\`) as
        // anchor. We're conservative: keep everything up to the first
        // real component intact.
        if components.count >= 2, components[0].hasSuffix(":") {
            stack.append(components[0])   // "C:"
            stack.append(components[1])   // "" (the leading `\`)
            startIndex = 2
            isAbsolute = true
        } else if components.first?.isEmpty == true {
            stack.append(Substring(""))   // leading `\`
            startIndex = 1
            isAbsolute = true
        } else {
            isAbsolute = false
        }
        #else
        if components.first?.isEmpty == true {
            stack.append(Substring(""))   // leading `/`
            startIndex = 1
            isAbsolute = true
        } else {
            isAbsolute = false
        }
        #endif

        for i in startIndex..<components.count {
            let part = components[i]
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if let last = stack.last, last != "" && last.last != ":" {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
                // Else: trying to walk above root; ignore.
                continue
            }
            stack.append(part)
        }

        var result = stack.joined(separator: String(sep))
        // After joining, an absolute Windows path looks like
        // `C:\foo\bar` (drive + sep + ...). An absolute POSIX path
        // looks like `/foo/bar`. Both correct as-is.
        // Drop trailing separator if any.
        if result.count > 1, result.last == sep {
            result.removeLast()
        }
        return result
    }

    /// True if `path` equals `workspacePath` or is contained inside
    /// it. Comparison is case-insensitive on Windows (NTFS is
    /// case-insensitive by default; matching Foundation's behaviour).
    private static func isPathInside(_ path: String, workspacePath: String) -> Bool {
        #if os(Windows)
        let p = path.lowercased()
        let ws = workspacePath.lowercased()
        let sep = "\\"
        #else
        let p = path
        let ws = workspacePath
        let sep = "/"
        #endif
        if p == ws { return true }
        return p.hasPrefix(ws + sep)
    }

    // ──────────────────────────────────────────────────────────────────
    // Retention (Phase 10)
    // ──────────────────────────────────────────────────────────────────

    /// Prune the oldest builds of `jobID` so at most `keepLast` remain.
    /// Returns the build numbers that were removed (ascending order,
    /// empty if nothing needed pruning).
    ///
    /// Removes the entire build directory for each pruned build —
    /// `status.json`, `log.txt`, `webhook.json`, `artifacts/`, and
    /// `workspace/` all go. Wrapped in `AtomicIO.withRetry` so Windows
    /// AV/indexer sharing-violations don't stop the prune.
    ///
    /// `keepLast` must be ≥ 1. Negative or zero values are treated as
    /// `1` defensively — we never want to delete the most recent
    /// build silently.
    @discardableResult
    public func pruneBuilds(jobID: String, keepLast: Int) throws -> [Int] {
        let keep = max(1, keepLast)
        let numbers = try listBuildNumbers(jobID: jobID)
        guard numbers.count > keep else { return [] }
        // listBuildNumbers returns ascending; drop the trailing `keep`.
        let doomed = Array(numbers.dropLast(keep))
        for n in doomed {
            let dir = buildDir(jobID: jobID, number: n)
            try AtomicIO.withRetry(attempts: 8) {
                if FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                }
            }
        }
        return doomed
    }
}

public enum ArtifactError: Error, Equatable, Sendable {
    case pathOutsideWorkspace(String)
    case missing(String)
    case invalidName(String)
}

/// Snapshot of an inbound webhook request. Persisted alongside each
/// triggered build so steps can read it via `SWIFTCI_WEBHOOK_BODY_PATH`.
public struct WebhookPayload: Codable, Sendable, Equatable {
    public let method: String
    public let receivedAt: Date
    /// Header names lowercased. Multi-value headers are joined with
    /// `", "` to match the HTTP wire format.
    public let headers: [String: String]
    /// UTF-8 body. Binary payloads are preserved as a hex-encoded
    /// `bodyBase64` field when `body` is empty / non-UTF-8.
    public let body: String
    /// Base64 of the raw body. Always populated so loss-less roundtrip
    /// is possible regardless of charset.
    public let bodyBase64: String

    public init(method: String,
                receivedAt: Date,
                headers: [String: String],
                rawBody: Data) {
        self.method = method
        self.receivedAt = receivedAt
        self.headers = headers
        self.body = String(data: rawBody, encoding: .utf8) ?? ""
        self.bodyBase64 = rawBody.base64EncodedString()
    }
}
