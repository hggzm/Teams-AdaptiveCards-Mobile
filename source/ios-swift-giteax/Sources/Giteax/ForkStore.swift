import Foundation
import Vapor

/// Phase 41: fork lineage tracker.
///
/// On-disk shape (one envelope, server-wide):
///
///     <root>/.giteax/forks.json
///       {
///         "version": 1,
///         "forks": [
///           { "child":  { "owner": "alice", "repo": "diffx" },
///             "parent": { "owner": "hggz",  "repo": "diffx" },
///             "createdAt": "...",
///             "createdBy": "alice" }
///         ]
///       }
///
/// One row per fork. The relation is single-parent (a fork has exactly
/// one upstream); siblings are derived by walking parents to a common
/// root. Listing forks of `<owner>/<repo>` returns every direct child
/// (NOT recursively — Gitea's UI does the same).
actor ForkStore {

    struct RepoRef: Sendable, Codable, Hashable {
        let owner: String
        let repo: String
    }

    struct Fork: Sendable, Codable {
        let child: RepoRef
        let parent: RepoRef
        let createdBy: String
        let createdAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var forks: [Fork]
    }

    enum StoreError: Error, AbortError {
        case alreadyExists(RepoRef)
        case parentNotFound(RepoRef)
        case ioFailed(String)
        case badEnvelope(String)
        case invalidInput(String)

        var status: HTTPResponseStatus {
            switch self {
            case .alreadyExists: .conflict
            case .parentNotFound: .notFound
            case .invalidInput: .badRequest
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .alreadyExists(let r):  "fork already registered: \(r.owner)/\(r.repo)"
            case .parentNotFound(let r): "no parent repo \(r.owner)/\(r.repo)"
            case .invalidInput(let d):   "invalid fork input: \(d)"
            case .ioFailed(let d):       "fork-store I/O failed: \(d)"
            case .badEnvelope(let d):    "fork-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    private var envelope: Envelope?

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = root
    }

    // MARK: - Read

    func parent(of child: RepoRef) throws -> RepoRef? {
        let env = try loadOrInit()
        return env.forks.first(where: { $0.child == child })?.parent
    }

    func childrenOf(_ parent: RepoRef) throws -> [Fork] {
        let env = try loadOrInit()
        return env.forks.filter { $0.parent == parent }
            .sorted { ($0.child.owner, $0.child.repo) < ($1.child.owner, $1.child.repo) }
    }

    /// Walk the parent chain from `from` upward looking for `target`.
    /// Returns true if `target` is `from` or any ancestor of `from`.
    /// Bounded at 64 hops to prevent runaway loops if the data is
    /// somehow corrupted.
    func isAncestor(_ target: RepoRef, of from: RepoRef) throws -> Bool {
        if target == from { return true }
        let env = try loadOrInit()
        var current = from
        var hops = 0
        while hops < 64 {
            guard let row = env.forks.first(where: { $0.child == current }) else {
                return false
            }
            if row.parent == target { return true }
            current = row.parent
            hops += 1
        }
        return false
    }

    /// True if `a` and `b` share a common fork ancestor (or one is the
    /// ancestor of the other, or both are the same repo). Used by the
    /// PR routes to decide whether `head` (in repo a) can be opened
    /// against `base` (in repo b).
    func sharesFamily(_ a: RepoRef, _ b: RepoRef) throws -> Bool {
        if a == b { return true }
        if try isAncestor(a, of: b) { return true }
        if try isAncestor(b, of: a) { return true }
        // Walk both up to their roots; intersect.
        let aChain = try chain(from: a)
        let bChain = try chain(from: b)
        let aSet = Set(aChain)
        for r in bChain where aSet.contains(r) { return true }
        return false
    }

    private func chain(from: RepoRef) throws -> [RepoRef] {
        let env = try loadOrInit()
        var out = [from]
        var cur = from
        var hops = 0
        while hops < 64 {
            guard let row = env.forks.first(where: { $0.child == cur }) else { break }
            out.append(row.parent)
            cur = row.parent
            hops += 1
        }
        return out
    }

    // MARK: - Write

    @discardableResult
    func registerFork(child: RepoRef, parent: RepoRef, createdBy: String) throws -> Fork {
        guard RepositoryService.validateSegment(child.owner),
              RepositoryService.validateSegment(child.repo),
              RepositoryService.validateSegment(parent.owner),
              RepositoryService.validateSegment(parent.repo)
        else { throw StoreError.invalidInput("invalid owner/repo segment") }

        var env = try loadOrInit()
        if env.forks.contains(where: { $0.child == child }) {
            throw StoreError.alreadyExists(child)
        }
        let now = Date()
        let fork = Fork(child: child, parent: parent, createdBy: createdBy, createdAt: now)
        env.forks.append(fork)
        try persist(env)
        return fork
    }

    @discardableResult
    func unregisterChild(_ child: RepoRef) throws -> Bool {
        var env = try loadOrInit()
        let before = env.forks.count
        env.forks.removeAll { $0.child == child }
        guard env.forks.count != before else { return false }
        try persist(env)
        return true
    }

    /// Phase 44: rewrite any fork rows whose `child` or `parent`
    /// references the old (owner, repo) pair so they now point at the
    /// new one. Used by transfer + rename. Returns the number of rows
    /// touched (0 means there was nothing to rewrite).
    @discardableResult
    func rewriteRepoRef(from old: RepoRef, to new: RepoRef) throws -> Int {
        if old == new { return 0 }
        var env = try loadOrInit()
        var touched = 0
        for i in env.forks.indices {
            var row = env.forks[i]
            var dirty = false
            if row.child == old {
                row = Fork(child: new, parent: row.parent, createdBy: row.createdBy, createdAt: row.createdAt)
                dirty = true
            }
            if row.parent == old {
                row = Fork(child: row.child, parent: new, createdBy: row.createdBy, createdAt: row.createdAt)
                dirty = true
            }
            if dirty {
                env.forks[i] = row
                touched += 1
            }
        }
        if touched > 0 { try persist(env) }
        return touched
    }

    // MARK: - Helpers

    private func loadOrInit() throws -> Envelope {
        if let cached = envelope { return cached }
        let url = envelopeURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let env = try dec.decode(Envelope.self, from: data)
                envelope = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(version: 1, forks: [])
        envelope = env
        return env
    }

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("forks.json")
    }

    private func persist(_ env: Envelope) throws {
        envelope = env
        let url = envelopeURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("forks.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.ioFailed("persist: \(error)")
        }
    }
}
