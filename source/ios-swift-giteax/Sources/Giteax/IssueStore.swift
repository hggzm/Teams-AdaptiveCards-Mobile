import Foundation
import Vapor

/// Filesystem-backed issue tracker, per (user/repo) namespace.
///
/// On-disk shape:
///
///     <root>/.giteax/repos/<user>/<repo>/issues.json
///       {
///         "version": 1,
///         "nextNumber": 5,
///         "issues": [
///           { number, title, body, authorName, createdAt, updatedAt,
///             state, labels[], commentCount }
///         ],
///         "comments": [
///           { id, issueNumber, authorName, body, createdAt }
///         ]
///       }
///
/// The whole envelope is loaded into memory the first time a repo is
/// touched, and every mutation persists the whole envelope atomically.
/// For a v0.0.8 issue tracker that's plenty -- a single repo with 100k
/// issues + 1M comments is ~ 200 MB JSON, which still loads in <1s on
/// SSD and edits in seconds. We deliberately defer SQLite until either
/// (a) issues outgrow this, or (b) we need cross-repo / cross-user
/// queries (search, mentions, dashboards) that can't be served from
/// in-memory snapshots.
///
/// Actor-isolated. One actor for the whole server -- contention is
/// negligible because each mutation is a single in-memory edit + one
/// `Data.write(to:options:.atomic)`.
actor IssueStore {

    // MARK: - Records

    enum State: String, Sendable, Codable, CaseIterable {
        case open
        case closed
    }

    struct Issue: Sendable, Codable {
        let number: Int
        var title: String
        var body: String
        let authorName: String
        let createdAt: Date
        var updatedAt: Date
        var state: State
        var labels: [String]
        var commentCount: Int
        /// Phase 42: optional milestone number (refers to
        /// `MilestoneStore.Milestone.number` for the same repo). nil =
        /// not assigned. Old envelopes without this key decode as nil.
        var milestone: Int?
        /// Phase 50: conversation lock. When `true`, comment writes are
        /// rejected with 423 unless the requester has admin on the repo.
        /// nil/false = unlocked. Old envelopes decode as nil.
        var locked: Bool?
        /// Phase 51: assigned usernames (validated against UserStore at
        /// the route layer). nil = never set; [] = explicitly cleared.
        /// Old envelopes decode as nil.
        var assignees: [String]?
    }

    struct Comment: Sendable, Codable {
        let id: Int
        let issueNumber: Int
        let authorName: String
        var body: String
        let createdAt: Date
    }

    /// Phase 52: lightweight emoji reaction on an issue.
    /// Uniqueness is enforced per (issueNumber, userName, content).
    struct Reaction: Sendable, Codable {
        let id: Int
        let issueNumber: Int
        let userName: String
        let content: String
        let createdAt: Date
    }

    /// Phase 52: Gitea/GitHub-compatible reaction vocabulary.
    static let allowedReactions: Set<String> = [
        "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes"
    ]

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextNumber: Int
        var nextCommentID: Int
        var issues: [Issue]
        var comments: [Comment]
        /// Phase 52: reaction id counter. Old envelopes decode as nil → 1.
        var nextReactionID: Int?
        /// Phase 52: reactions store. Old envelopes decode as nil → [].
        var reactions: [Reaction]?
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case issueNotFound(number: Int)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)
        case locked(number: Int)
        case reactionNotFound(id: Int)
        case reactionConflict

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound:      .notFound
            case .issueNotFound:     .notFound
            case .invalidInput:      .badRequest
            case .ioFailed:          .internalServerError
            case .badEnvelope:       .internalServerError
            case .locked:            HTTPResponseStatus(statusCode: 423, reasonPhrase: "Locked")
            case .reactionNotFound:  .notFound
            case .reactionConflict:  .conflict
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r):
                return "no repository at \(u)/\(r)"
            case .issueNotFound(let n):
                return "issue #\(n) not found"
            case .invalidInput(let d):
                return "invalid issue input: \(d)"
            case .ioFailed(let d):
                return "issue-store I/O failed: \(d)"
            case .badEnvelope(let d):
                return "issue-store JSON malformed: \(d)"
            case .locked(let n):
                return "issue #\(n) is locked"
            case .reactionNotFound(let id):
                return "reaction #\(id) not found"
            case .reactionConflict:
                return "reaction already exists for this user+content"
            }
        }
    }

    // MARK: - Init

    /// Filesystem root that holds the per-repo issue files. Sibling to
    /// the users.json store.
    let root: URL

    /// In-memory cache. Key: `"<user>/<repo>"`. Loaded lazily.
    private var envelopes: [String: Envelope] = [:]

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.root = root
    }

    /// Phase 44: drop cached envelope for `user/repo`. Called by repo
    /// transfer/rename right before the on-disk move.
    func evictRepo(user: String, repo: String) {
        envelopes.removeValue(forKey: "\(user)/\(repo)")
    }

    // MARK: - Read

    /// List issues for a repo with optional state + label filtering.
    /// `state == nil` returns both open and closed.
    func list(
        user: String,
        repo: String,
        state: State? = nil,
        label: String? = nil,
        milestone: Int? = nil,
        limit: Int = 50
    ) throws -> [Issue] {
        let env = try loadOrInit(user: user, repo: repo)
        var out = env.issues
        if let state { out = out.filter { $0.state == state } }
        if let label { out = out.filter { $0.labels.contains(label) } }
        if let milestone { out = out.filter { $0.milestone == milestone } }
        // Sort newest-first by number (== creation order). Clamp to limit.
        out.sort { $0.number > $1.number }
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    /// Single issue by number. Throws `issueNotFound` when missing.
    func get(user: String, repo: String, number: Int) throws -> Issue {
        let env = try loadOrInit(user: user, repo: repo)
        guard let issue = env.issues.first(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        return issue
    }

    /// Comments on a single issue, sorted by creation time.
    func comments(user: String, repo: String, number: Int) throws -> [Comment] {
        let env = try loadOrInit(user: user, repo: repo)
        guard env.issues.contains(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        return env.comments.filter { $0.issueNumber == number }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Mutate

    @discardableResult
    func create(
        user: String,
        repo: String,
        authorName: String,
        title: String,
        body: String,
        labels: [String],
        milestone: Int? = nil
    ) throws -> Issue {
        try Self.validateTitle(title)
        let now = Date()
        var env = try loadOrInit(user: user, repo: repo)
        let number = env.nextNumber
        env.nextNumber += 1
        let issue = Issue(
            number: number,
            title: title,
            body: body,
            authorName: authorName,
            createdAt: now,
            updatedAt: now,
            state: .open,
            labels: Self.normalizeLabels(labels),
            commentCount: 0,
            milestone: milestone,
            locked: nil,
            assignees: nil
        )
        env.issues.append(issue)
        try persist(env, user: user, repo: repo)
        return issue
    }

    @discardableResult
    func update(
        user: String,
        repo: String,
        number: Int,
        title: String? = nil,
        body: String? = nil,
        state: State? = nil,
        labels: [String]? = nil,
        milestone: Int?? = nil
    ) throws -> Issue {
        if let t = title { try Self.validateTitle(t) }
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.issues.firstIndex(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        var issue = env.issues[idx]
        if let t = title  { issue.title = t }
        if let b = body   { issue.body = b }
        if let s = state  { issue.state = s }
        if let l = labels { issue.labels = Self.normalizeLabels(l) }
        // Double-optional: nil = leave alone; .some(nil) = clear assignment;
        // .some(.some(n)) = assign to milestone #n.
        if let m = milestone { issue.milestone = m }
        issue.updatedAt = Date()
        env.issues[idx] = issue
        try persist(env, user: user, repo: repo)
        return issue
    }

    @discardableResult
    func addComment(
        user: String,
        repo: String,
        number: Int,
        authorName: String,
        body: String
    ) throws -> Comment {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalidInput("comment body is empty")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard let issueIdx = env.issues.firstIndex(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        let id = env.nextCommentID
        env.nextCommentID += 1
        let comment = Comment(
            id: id,
            issueNumber: number,
            authorName: authorName,
            body: body,
            createdAt: Date()
        )
        env.comments.append(comment)
        env.issues[issueIdx].commentCount += 1
        env.issues[issueIdx].updatedAt = comment.createdAt
        try persist(env, user: user, repo: repo)
        return comment
    }

    /// Phase 50: set conversation lock state. Returns the updated issue.
    @discardableResult
    func setLocked(
        user: String,
        repo: String,
        number: Int,
        locked: Bool
    ) throws -> Issue {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.issues.firstIndex(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        env.issues[idx].locked = locked ? true : nil
        env.issues[idx].updatedAt = Date()
        try persist(env, user: user, repo: repo)
        return env.issues[idx]
    }

    /// Phase 51: cheap read of the lock bit (true iff `issue.locked == true`).
    /// Throws `issueNotFound` when missing.
    func isLocked(user: String, repo: String, number: Int) throws -> Bool {
        let env = try loadOrInit(user: user, repo: repo)
        guard let issue = env.issues.first(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        return issue.locked == true
    }

    /// Phase 51: replace the issue's assignee set. The list is
    /// normalized (trim, drop empty, dedupe, cap at 10) before persist.
    /// Caller is expected to have validated each username exists in
    /// `UserStore` already. Returns the updated issue.
    @discardableResult
    func setAssignees(
        user: String,
        repo: String,
        number: Int,
        assignees: [String]
    ) throws -> Issue {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.issues.firstIndex(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        let norm = Self.normalizeAssignees(assignees)
        env.issues[idx].assignees = norm.isEmpty ? [] : norm
        env.issues[idx].updatedAt = Date()
        try persist(env, user: user, repo: repo)
        return env.issues[idx]
    }

    // MARK: - Reactions (Phase 52)

    /// List reactions for an issue, sorted by id (== creation order).
    func reactions(user: String, repo: String, number: Int) throws -> [Reaction] {
        let env = try loadOrInit(user: user, repo: repo)
        guard env.issues.contains(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        return (env.reactions ?? []).filter { $0.issueNumber == number }
            .sorted { $0.id < $1.id }
    }

    /// Add a reaction. Rejects duplicates per (issue, user, content).
    @discardableResult
    func addReaction(
        user: String,
        repo: String,
        number: Int,
        userName: String,
        content: String
    ) throws -> Reaction {
        guard Self.allowedReactions.contains(content) else {
            throw StoreError.invalidInput("unsupported reaction content: \(content)")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard env.issues.contains(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        var rs = env.reactions ?? []
        if rs.contains(where: { $0.issueNumber == number && $0.userName == userName && $0.content == content }) {
            throw StoreError.reactionConflict
        }
        let nextID = env.nextReactionID ?? 1
        let r = Reaction(
            id: nextID,
            issueNumber: number,
            userName: userName,
            content: content,
            createdAt: Date()
        )
        rs.append(r)
        env.reactions = rs
        env.nextReactionID = nextID + 1
        try persist(env, user: user, repo: repo)
        return r
    }

    /// Remove a reaction by id. Returns the deleted reaction so the
    /// route layer can authorize "owner or admin" without a second
    /// round-trip. Throws `reactionNotFound` when missing.
    @discardableResult
    func removeReaction(
        user: String,
        repo: String,
        number: Int,
        reactionID: Int
    ) throws -> Reaction {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.issues.contains(where: { $0.number == number }) else {
            throw StoreError.issueNotFound(number: number)
        }
        var rs = env.reactions ?? []
        guard let idx = rs.firstIndex(where: { $0.id == reactionID && $0.issueNumber == number }) else {
            throw StoreError.reactionNotFound(id: reactionID)
        }
        let removed = rs.remove(at: idx)
        env.reactions = rs
        try persist(env, user: user, repo: repo)
        return removed
    }

    // MARK: - Helpers

    private static func validateTitle(_ s: String) throws {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("title is empty")
        }
        guard trimmed.count <= 256 else {
            throw StoreError.invalidInput("title must be <= 256 characters")
        }
    }

    /// Strip empty / whitespace-only labels, trim, de-dupe (preserving order).
    private static func normalizeLabels(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for label in raw {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= 80 else { continue }
            if seen.insert(trimmed).inserted { out.append(trimmed) }
        }
        return out
    }

    /// Phase 51: trim, drop empty, de-dupe assignees and cap at 10.
    /// Username syntax validation is done at the route layer via
    /// `RepositoryService.validateSegment`. Existence in `UserStore` is
    /// also enforced at the route layer (the store can't see users).
    static func normalizeAssignees(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in raw {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= 64 else { continue }
            if seen.insert(trimmed).inserted { out.append(trimmed) }
            if out.count >= 10 { break }
        }
        return out
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let key = "\(user)/\(repo)"
        if let cached = envelopes[key] { return cached }
        let url = envelopeURL(user: user, repo: repo)

        // The repo must EXIST under GITEAX_ROOT before we'll track issues
        // for it. This matches Gitea's behavior: you can't open an issue
        // on a repo that isn't hosted on the server.
        if !repoExistsOnDisk(user: user, repo: repo) {
            throw StoreError.repoNotFound(user: user, repo: repo)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let env = try decoder.decode(Envelope.self, from: data)
                envelopes[key] = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(
            version: 1,
            nextNumber: 1,
            nextCommentID: 1,
            issues: [],
            comments: [],
            nextReactionID: 1,
            reactions: []
        )
        envelopes[key] = env
        return env
    }

    /// Repo presence check piggybacks on RepositoryService's layout
    /// (bare `<repo>.git` preferred, working-tree fallback).
    private func repoExistsOnDisk(user: String, repo: String) -> Bool {
        let bare = root.appendingPathComponent(user)
            .appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("issues.json")
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        envelopes[key] = env
        let url = envelopeURL(user: user, repo: repo)
        // Make sure the directory tree exists.
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.ioFailed("mkdir: \(error)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(env)
        } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        // Same atomic-ish dance as UserStore -- no FileManager.replaceItemAt
        // on swift-corelibs-foundation/Windows.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("issues.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
