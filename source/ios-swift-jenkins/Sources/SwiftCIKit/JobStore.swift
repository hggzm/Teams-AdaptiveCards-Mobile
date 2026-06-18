import Foundation

/// Filesystem-backed job catalog.
///
/// v0 storage layout (per HANDOFF §1 / §6):
/// ```
/// <root>/
///   jobs/
///     <id>/
///       config.yaml         ← the pipeline definition as authored
///       builds/             ← reserved for Phase 3 (executor)
/// ```
///
/// `<id>` is a hyphenated lowercase slug of `pipeline.name` plus an 8-char
/// random suffix; collisions cause a retry. The id is URL-safe.
public struct JobStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Convenience initializer that accepts a filesystem path.
    public init(rootPath: String) {
        self.init(root: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    // ──────────────────────────────────────────────────────────────────
    // Public API
    // ──────────────────────────────────────────────────────────────────

    /// Persist a pipeline as a new job. Returns the assigned id.
    @discardableResult
    public func createJob(from pipeline: Pipeline) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobsDir = root.appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobsDir, withIntermediateDirectories: true)

        // Try up to 5 ids before giving up; collisions are essentially
        // impossible for 8 hex chars (~4×10⁹ keyspace) within one process.
        for _ in 0..<5 {
            let id = Self.makeID(for: pipeline.name)
            let jobDir = jobsDir.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: jobDir.path) { continue }
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: jobDir.appendingPathComponent("builds", isDirectory: true),
                withIntermediateDirectories: false
            )
            let yaml = try pipeline.encodeYAML()
            let configURL = jobDir.appendingPathComponent("config.yaml")
            try AtomicIO.writeString(yaml, to: configURL)
            return id
        }
        throw JobStoreError.idCollision
    }

    /// Load a previously persisted job's pipeline. Returns nil if the job
    /// does not exist; throws if the on-disk YAML is unparseable.
    public func loadJob(id: String) throws -> Pipeline? {
        let configURL = jobDir(for: id).appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let yaml = try AtomicIO.readString(from: configURL)
        return try Pipeline.decode(yaml: yaml)
    }

    /// List all known job ids, sorted lexicographically.
    public func listJobIDs() throws -> [String] {
        let jobsDir = root.appendingPathComponent("jobs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: jobsDir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: jobsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // ──────────────────────────────────────────────────────────────────
    // Internals
    // ──────────────────────────────────────────────────────────────────

    /// Directory `<root>/jobs/<id>/`. Internal so extensions in this
    /// module (e.g. `JobStore+Builds.swift`) can reach it.
    internal func jobDir(for id: String) -> URL {
        root.appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Build an id like `build-test-3f4a9c12` from a pipeline name.
    /// Slug keeps `[a-z0-9-]` only, collapses runs of separators, trims to
    /// 40 chars; suffix is 8 hex chars from a 32-bit random value.
    static func makeID(for name: String) -> String {
        let lowered = name.lowercased()
        var slugChars = [Character]()
        var lastWasSeparator = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                slugChars.append(ch)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slugChars.append("-")
                lastWasSeparator = true
            }
        }
        // Trim trailing separator.
        while slugChars.last == "-" { slugChars.removeLast() }
        // Trim leading separator.
        while slugChars.first == "-" { slugChars.removeFirst() }
        var slug = String(slugChars.prefix(40))
        if slug.isEmpty { slug = "job" }
        let suffix = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        return "\(slug)-\(suffix)"
    }
}

public enum JobStoreError: Error, Equatable, Sendable {
    case idCollision
    case noSuchJob(String)
}
