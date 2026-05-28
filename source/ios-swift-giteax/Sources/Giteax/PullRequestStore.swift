import Foundation
import SwiftGitX
import Vapor

/// Filesystem-backed pull-request store, per (user/repo).
///
/// On-disk shape (sibling of issues.json):
///
///     <root>/.giteax/repos/<user>/<repo>/prs.json
///       {
///         "version": 1,
///         "nextNumber": 5,
///         "pullRequests": [
///           { number, title, body, authorName,
///             headBranch, baseBranch,
///             headCommit, baseCommit,        // snapshot at PR-open time
///             createdAt, updatedAt,
///             state,                          // "open" / "merged" / "closed"
///             mergedAt?, mergedBy?, mergeCommit?,
///             commentCount }
///         ],
///         "comments": [
///           { id, prNumber, authorName, body, createdAt }
///         ]
///       }
///
/// PRs reuse the same per-repo JSON envelope shape and atomic-write
/// dance as `IssueStore`. The two stores are deliberately separate
/// files (not unified) because in real Gitea / GitHub workflows
/// you'll routinely have far more issues than PRs, and most issue
/// queries don't want PR rows folded in.
///
/// Merge model in v0.0.20:
///   * Fast-forward when head strictly descends from base. Same
///     behaviour as v0.0.9: re-create the base ref pointing at
///     head's commit via SwiftGitX `branch.create(force: true)`.
///   * Otherwise (`.diverged`), attempt a 3-way tree merge through
///     the Phase 16 SwiftGitX bridging (`git_merge_trees` +
///     `git_commit_create`). On a clean merge we synthesise a real
///     2-parent merge commit and advance the base ref to it. On
///     conflict we surface 409 Conflict with a structured
///     `conflicts` payload (path + ancestor/ours/theirs OIDs).
/// No favor / strategy is exposed at the REST surface; libgit2
/// defaults (recursive, `GIT_MERGE_FILE_FAVOR_NORMAL`) are used.
actor PullRequestStore {

    // MARK: - Records

    enum State: String, Sendable, Codable, CaseIterable {
        case open
        case closed
        case merged
    }

    /// Result of a mergeability probe. Computed lazily on demand.
    /// The probe is intentionally cheap (FF-graph walk only); it does
    /// NOT attempt a 3-way merge to verify conflict-freeness. A
    /// `.diverged` PR may still be cleanly mergeable via 3-way; the
    /// authoritative answer is only known when the actual merge runs.
    enum MergeStatus: String, Sendable, Codable {
        /// `head` strictly descends from `base` -> FF-merge possible.
        case fastForward
        /// `base` already includes every commit in `head` -> nothing to merge.
        case upToDate
        /// `head` does not contain `base`. May still 3-way merge cleanly.
        case diverged
        /// Either ref couldn't be resolved.
        case invalidRefs
    }

    /// One unresolved entry from a 3-way merge. Mirrors
    /// `SwiftGitX.Repository.MergeConflict` but uses plain hex OID
    /// strings so it can be JSON-encoded directly.
    struct ConflictEntry: Sendable, Codable {
        let path: String
        let ancestor: ConflictSide?
        let ours: ConflictSide?
        let theirs: ConflictSide?
    }

    struct ConflictSide: Sendable, Codable {
        let oid: String   // "" if libgit2 reported a zero OID
        let path: String
        let mode: UInt32
    }

    struct PullRequest: Sendable, Codable {
        let number: Int
        var title: String
        var body: String
        let authorName: String
        let headBranch: String
        let baseBranch: String
        /// Phase 41 cross-fork PRs: when the head ref came from a fork
        /// (a different `<owner>/<repo>` from the base), these capture
        /// the original fork coordinates. The on-disk `headBranch` is
        /// rewritten to a local mirror ref of the form
        /// `__fork__/<headOwner>/<headRepo>/<originalBranch>` so the
        /// existing merge machinery resolves it as a local branch in
        /// the base repo. nil for same-repo PRs.
        var headOwner: String?
        var headRepo: String?
        var headOriginalBranch: String?
        /// Snapshot of the head ref at the time the PR was opened. Updated
        /// on every PATCH that changes head. (Phase 11+ will refresh this
        /// automatically on push.)
        var headCommit: String
        /// Snapshot of base at PR-open time. NOT auto-refreshed (the base
        /// branch could have moved since); use the live merge probe for
        /// the up-to-date answer.
        var baseCommit: String
        let createdAt: Date
        var updatedAt: Date
        var state: State
        var mergedAt: Date?
        var mergedBy: String?
        var mergeCommit: String?
        var commentCount: Int
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
        let prNumber: Int
        let authorName: String
        var body: String
        let createdAt: Date
    }

    /// Phase 52: emoji reaction on a PR. Unique per (prNumber,userName,content).
    struct Reaction: Sendable, Codable {
        let id: Int
        let prNumber: Int
        let userName: String
        let content: String
        let createdAt: Date
    }

    /// Phase 52: shared reaction vocabulary (matches IssueStore).
    static let allowedReactions: Set<String> = [
        "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes"
    ]

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextNumber: Int
        var nextCommentID: Int
        var pullRequests: [PullRequest]
        var comments: [Comment]
        /// Phase 52: reaction id counter. Old envelopes decode as nil → 1.
        var nextReactionID: Int?
        /// Phase 52: reactions store. Old envelopes decode as nil → [].
        var reactions: [Reaction]?
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case prNotFound(number: Int)
        case branchNotFound(String)
        case invalidInput(String)
        case alreadyMerged(number: Int)
        case alreadyClosed(number: Int)
        case notMergeable(reason: String)
        /// 3-way merge produced one or more conflicts. The associated
        /// list is exposed on the 409 response body so the client can
        /// render which paths need manual resolution.
        case mergeConflict(conflicts: [ConflictEntry])
        case ioFailed(String)
        case badEnvelope(String)
        case locked(number: Int)
        case reactionNotFound(id: Int)
        case reactionConflict

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound:      .notFound
            case .prNotFound:        .notFound
            case .branchNotFound:    .notFound
            case .invalidInput:      .badRequest
            case .alreadyMerged:     .conflict
            case .alreadyClosed:     .conflict
            case .notMergeable:      .conflict
            case .mergeConflict:     .conflict
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
            case .prNotFound(let n):
                return "pull request #\(n) not found"
            case .branchNotFound(let b):
                return "branch '\(b)' not found"
            case .invalidInput(let d):
                return "invalid PR input: \(d)"
            case .alreadyMerged(let n):
                return "pull request #\(n) is already merged"
            case .alreadyClosed(let n):
                return "pull request #\(n) is closed"
            case .notMergeable(let r):
                return "not mergeable: \(r)"
            case .mergeConflict(let conflicts):
                let paths = conflicts.map(\.path).joined(separator: ", ")
                return "3-way merge produced conflicts: \(paths)"
            case .ioFailed(let d):
                return "pr-store I/O failed: \(d)"
            case .badEnvelope(let d):
                return "pr-store JSON malformed: \(d)"
            case .locked(let n):
                return "pull request #\(n) is locked"
            case .reactionNotFound(let id):
                return "reaction #\(id) not found"
            case .reactionConflict:
                return "reaction already exists for this user+content"
            }
        }
    }

    // MARK: - Init

    let root: URL
    /// Reused for ref resolution + branch lookups during merge ops.
    let repoService: RepositoryService

    /// In-memory cache. Key: `"<user>/<repo>"`.
    private var envelopes: [String: Envelope] = [:]

    init(root: URL, repoService: RepositoryService) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.root = root
        self.repoService = repoService
    }

    /// Phase 44: drop cached envelope for `user/repo`.
    func evictRepo(user: String, repo: String) {
        envelopes.removeValue(forKey: "\(user)/\(repo)")
    }

    // MARK: - Read

    func list(
        user: String,
        repo: String,
        state: State? = nil,
        limit: Int = 50
    ) throws -> [PullRequest] {
        let env = try loadOrInit(user: user, repo: repo)
        var out = env.pullRequests
        if let state { out = out.filter { $0.state == state } }
        out.sort { $0.number > $1.number }
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    func get(user: String, repo: String, number: Int) throws -> PullRequest {
        let env = try loadOrInit(user: user, repo: repo)
        guard let pr = env.pullRequests.first(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        return pr
    }

    func comments(user: String, repo: String, number: Int) throws -> [Comment] {
        let env = try loadOrInit(user: user, repo: repo)
        guard env.pullRequests.contains(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        return env.comments.filter { $0.prNumber == number }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Mutate

    /// Open a new PR. Both branches must already exist in the repo;
    /// no remote branches, no forking, no cross-repo PRs in v0.0.9.
    @discardableResult
    func create(
        user: String,
        repo: String,
        authorName: String,
        title: String,
        body: String,
        headBranch: String,
        baseBranch: String,
        headOwner: String? = nil,
        headRepo: String? = nil,
        headOriginalBranch: String? = nil
    ) throws -> PullRequest {
        try Self.validateTitle(title)
        guard headBranch != baseBranch else {
            throw StoreError.invalidInput("head and base branches must differ")
        }

        // Resolve both branches in the repo to capture commit snapshots.
        let snapshots = try resolveBranchPair(
            user: user, repo: repo, head: headBranch, base: baseBranch
        )

        var env = try loadOrInit(user: user, repo: repo)
        let number = env.nextNumber
        env.nextNumber += 1
        let now = Date()
        let pr = PullRequest(
            number: number,
            title: title,
            body: body,
            authorName: authorName,
            headBranch: headBranch,
            baseBranch: baseBranch,
            headOwner: headOwner,
            headRepo: headRepo,
            headOriginalBranch: headOriginalBranch,
            headCommit: snapshots.headOID,
            baseCommit: snapshots.baseOID,
            createdAt: now,
            updatedAt: now,
            state: .open,
            mergedAt: nil,
            mergedBy: nil,
            mergeCommit: nil,
            commentCount: 0,
            locked: nil,
            assignees: nil
        )
        env.pullRequests.append(pr)
        try persist(env, user: user, repo: repo)
        return pr
    }

    @discardableResult
    func update(
        user: String,
        repo: String,
        number: Int,
        title: String? = nil,
        body: String? = nil,
        state: State? = nil
    ) throws -> PullRequest {
        if let t = title { try Self.validateTitle(t) }
        // Don't allow callers to set state=merged via PATCH -- merge has
        // its own dedicated entry point so the merge bookkeeping
        // (mergedBy/mergedAt/mergeCommit) stays consistent.
        if state == .merged {
            throw StoreError.invalidInput("use POST .../merge to mark a PR merged")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.pullRequests.firstIndex(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        var pr = env.pullRequests[idx]
        if pr.state == .merged {
            throw StoreError.alreadyMerged(number: number)
        }
        if let t = title { pr.title = t }
        if let b = body  { pr.body = b }
        if let s = state { pr.state = s }
        pr.updatedAt = Date()
        env.pullRequests[idx] = pr
        try persist(env, user: user, repo: repo)
        return pr
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
        guard let prIdx = env.pullRequests.firstIndex(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        let id = env.nextCommentID
        env.nextCommentID += 1
        let comment = Comment(
            id: id,
            prNumber: number,
            authorName: authorName,
            body: body,
            createdAt: Date()
        )
        env.comments.append(comment)
        env.pullRequests[prIdx].commentCount += 1
        env.pullRequests[prIdx].updatedAt = comment.createdAt
        try persist(env, user: user, repo: repo)
        return comment
    }

    /// Phase 50: set conversation lock state.
    @discardableResult
    func setLocked(
        user: String,
        repo: String,
        number: Int,
        locked: Bool
    ) throws -> PullRequest {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.pullRequests.firstIndex(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        env.pullRequests[idx].locked = locked ? true : nil
        env.pullRequests[idx].updatedAt = Date()
        try persist(env, user: user, repo: repo)
        return env.pullRequests[idx]
    }

    /// Phase 50: cheap read of the lock bit.
    func isLocked(user: String, repo: String, number: Int) throws -> Bool {
        let env = try loadOrInit(user: user, repo: repo)
        guard let pr = env.pullRequests.first(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        return pr.locked == true
    }

    /// Phase 51: replace the PR's assignee set. The list is normalized
    /// (trim, drop empty, dedupe, cap at 10) before persist. Caller is
    /// expected to have validated each username exists in `UserStore`.
    @discardableResult
    func setAssignees(
        user: String,
        repo: String,
        number: Int,
        assignees: [String]
    ) throws -> PullRequest {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.pullRequests.firstIndex(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        let norm = Self.normalizeAssignees(assignees)
        env.pullRequests[idx].assignees = norm.isEmpty ? [] : norm
        env.pullRequests[idx].updatedAt = Date()
        try persist(env, user: user, repo: repo)
        return env.pullRequests[idx]
    }

    /// Phase 51: trim, drop empty, de-dupe assignees and cap at 10.
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

    // MARK: - Reactions (Phase 52)

    func reactions(user: String, repo: String, number: Int) throws -> [Reaction] {
        let env = try loadOrInit(user: user, repo: repo)
        guard env.pullRequests.contains(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        return (env.reactions ?? []).filter { $0.prNumber == number }
            .sorted { $0.id < $1.id }
    }

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
        guard env.pullRequests.contains(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        var rs = env.reactions ?? []
        if rs.contains(where: { $0.prNumber == number && $0.userName == userName && $0.content == content }) {
            throw StoreError.reactionConflict
        }
        let nextID = env.nextReactionID ?? 1
        let r = Reaction(
            id: nextID,
            prNumber: number,
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

    @discardableResult
    func removeReaction(
        user: String,
        repo: String,
        number: Int,
        reactionID: Int
    ) throws -> Reaction {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.pullRequests.contains(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        var rs = env.reactions ?? []
        guard let idx = rs.firstIndex(where: { $0.id == reactionID && $0.prNumber == number }) else {
            throw StoreError.reactionNotFound(id: reactionID)
        }
        let removed = rs.remove(at: idx)
        env.reactions = rs
        try persist(env, user: user, repo: repo)
        return removed
    }

    // MARK: - Merge

    /// Probe whether this PR can be FF-merged right now. Always
    /// resolves the *live* head and base branches (not the snapshots
    /// stored on the PR record).
    func mergeStatus(user: String, repo: String, number: Int) throws -> (MergeStatus, String, String) {
        let pr = try get(user: user, repo: repo, number: number)
        do {
            return try withBranchPair(user: user, repo: repo,
                                      head: pr.headBranch, base: pr.baseBranch) { pair in
                let status = Self.ffStatus(
                    headOID: pair.headOID,
                    baseOID: pair.baseOID,
                    headCommit: pair.headCommit
                )
                return (status, pair.headOID, pair.baseOID)
            }
        } catch {
            return (.invalidRefs, "", "")
        }
    }

    /// Perform the merge. Tries fast-forward first; falls back to a
    /// 3-way merge through SwiftGitX's Phase 16 bridging when the
    /// branches have diverged. Returns the updated PR with `.merged`
    /// state and `mergedBy`/`mergedAt`/`mergeCommit` populated.
    /// Throws ``StoreError/mergeConflict(conflicts:)`` (409) when the
    /// 3-way merge produces unresolvable conflicts.
    @discardableResult
    func merge(
        user: String,
        repo: String,
        number: Int,
        mergedBy: String,
        mergedByEmail: String? = nil
    ) throws -> PullRequest {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.pullRequests.firstIndex(where: { $0.number == number }) else {
            throw StoreError.prNotFound(number: number)
        }
        var pr = env.pullRequests[idx]
        switch pr.state {
        case .merged:  throw StoreError.alreadyMerged(number: number)
        case .closed:  throw StoreError.alreadyClosed(number: number)
        case .open:    break
        }
        // Open the repo ONCE, keep it alive for the whole merge transaction.
        // Commit's repositoryPointer is owned by the parent Repository's
        // libgit2 handle -- if we let the Repository go out of scope between
        // the resolve and the parents walk, the commit's pointer becomes
        // dangling and commit.parents silently returns empty (or worse).
        let outcome = try withBranchPair(
            user: user, repo: repo,
            head: pr.headBranch, base: pr.baseBranch
        ) { pair throws -> MergeOutcome in
            let status = Self.ffStatus(
                headOID: pair.headOID,
                baseOID: pair.baseOID,
                headCommit: pair.headCommit
            )
            switch status {
            case .upToDate:
                return .upToDate
            case .invalidRefs:
                return .invalidRefs
            case .fastForward:
                // Advance the base branch ref to head's commit.
                _ = try pair.repo.branch.create(
                    named: pr.baseBranch,
                    target: pair.headCommit,
                    force: true
                )
                return .fastForward(mergeOID: pair.headOID)
            case .diverged:
                return try Self.threeWayMerge(
                    pair: pair,
                    pr: pr,
                    mergedBy: mergedBy,
                    mergedByEmail: mergedByEmail
                )
            }
        }
        let mergeOID: String
        switch outcome {
        case .upToDate:
            throw StoreError.notMergeable(reason: "base already includes head; nothing to merge")
        case .invalidRefs:
            throw StoreError.notMergeable(reason: "could not resolve one of the branches")
        case .fastForward(let oid):
            mergeOID = oid
        case .threeWay(let oid):
            mergeOID = oid
        case .conflict(let conflicts):
            throw StoreError.mergeConflict(conflicts: conflicts)
        }
        pr.state = .merged
        let now = Date()
        pr.mergedAt = now
        pr.mergedBy = mergedBy
        pr.mergeCommit = mergeOID
        pr.updatedAt = now
        env.pullRequests[idx] = pr
        try persist(env, user: user, repo: repo)
        return pr
    }

    // MARK: - Merge outcomes (internal)

    private enum MergeOutcome {
        case upToDate
        case invalidRefs
        case fastForward(mergeOID: String)
        case threeWay(mergeOID: String)
        case conflict(conflicts: [ConflictEntry])
    }

    /// Run a 3-way merge of `head` into `base` using SwiftGitX's
    /// Phase 16 bridging. Updates the base branch ref on success.
    private static func threeWayMerge(
        pair: BranchPair,
        pr: PullRequest,
        mergedBy: String,
        mergedByEmail: String?
    ) throws -> MergeOutcome {
        // Determine the merge base. nil result means orphan branches
        // (no common ancestor); libgit2 still merges with NULL ancestor.
        let baseTreeForMerge: Tree?
        do {
            if let mbOID = try pair.repo.mergeBase(pair.baseCommit.id, pair.headCommit.id) {
                let mbCommit: Commit = try pair.repo.show(id: mbOID)
                baseTreeForMerge = try mbCommit.tree
            } else {
                baseTreeForMerge = nil
            }
        } catch {
            throw StoreError.notMergeable(
                reason: "could not compute merge base: \(error)"
            )
        }

        let oursTree: Tree
        let theirsTree: Tree
        do {
            // Convention: base branch is "ours", PR head is "theirs".
            // This matches `git merge <head>` run on the base branch.
            oursTree = try pair.baseCommit.tree
            theirsTree = try pair.headCommit.tree
        } catch {
            throw StoreError.notMergeable(reason: "could not load branch trees: \(error)")
        }

        let result: Repository.MergeTreeResult
        do {
            result = try pair.repo.mergeTrees(
                ancestor: baseTreeForMerge,
                ours: oursTree,
                theirs: theirsTree
            )
        } catch {
            throw StoreError.notMergeable(reason: "git_merge_trees failed: \(error)")
        }

        if !result.conflicts.isEmpty || result.mergedTreeID == nil {
            let entries = result.conflicts.map { c in
                ConflictEntry(
                    path: c.path,
                    ancestor: c.ancestor.map(Self.toSide),
                    ours: c.ours.map(Self.toSide),
                    theirs: c.theirs.map(Self.toSide)
                )
            }
            return .conflict(conflicts: entries)
        }
        guard let mergedTreeID = result.mergedTreeID else {
            // Defensive: shouldn't happen given the check above.
            return .conflict(conflicts: [])
        }

        // Build a 2-parent merge commit: parent[0] = base, parent[1] = head.
        let signature = Signature(
            name: mergedBy,
            email: mergedByEmail ?? "\(mergedBy)@giteax.local"
        )
        let message = """
            Merge pull request #\(pr.number) from \(pr.headBranch) into \(pr.baseBranch)

            \(pr.title)
            """

        let mergeOID: OID
        do {
            mergeOID = try pair.repo.createMergeCommit(
                treeID: mergedTreeID,
                parents: [pair.baseCommit, pair.headCommit],
                author: signature,
                committer: signature,
                message: message,
                updatingRef: "refs/heads/\(pr.baseBranch)"
            )
        } catch {
            throw StoreError.notMergeable(reason: "could not create merge commit: \(error)")
        }
        return .threeWay(mergeOID: mergeOID.hex)
    }

    private static func toSide(_ s: Repository.MergeConflictSide) -> ConflictSide {
        let hex = s.id == .zero ? "" : s.id.hex
        return ConflictSide(oid: hex, path: s.path, mode: s.mode)
    }

    // MARK: - Helpers

    private struct BranchPair: Sendable {
        let headOID: String
        let baseOID: String
        let headCommit: Commit
        let baseCommit: Commit
        /// The Repository must outlive everything else here -- the commits'
        /// repositoryPointer is owned by this libgit2 handle.
        let repo: Repository
    }

    /// Open the repo, resolve both branches, and invoke `body` while the
    /// Repository is guaranteed alive. This is the only safe way to walk
    /// `commit.parents` because Commit's repositoryPointer would dangle if
    /// the parent Repository got deinit'd between the resolve and the walk.
    private func withBranchPair<T>(
        user: String, repo: String, head: String, base: String,
        _ body: (BranchPair) throws -> T
    ) throws -> T {
        let r = try repoService.open(user: user, repo: repo)
        let headBr: Branch
        let baseBr: Branch
        do {
            headBr = try r.branch.get(named: head)
        } catch {
            throw StoreError.branchNotFound(head)
        }
        do {
            baseBr = try r.branch.get(named: base)
        } catch {
            throw StoreError.branchNotFound(base)
        }
        guard let headCommit = headBr.target as? Commit,
              let baseCommit = baseBr.target as? Commit
        else {
            throw StoreError.invalidInput("branch does not point at a commit")
        }
        let pair = BranchPair(
            headOID: headCommit.id.hex,
            baseOID: baseCommit.id.hex,
            headCommit: headCommit,
            baseCommit: baseCommit,
            repo: r
        )
        return try body(pair)
    }

    /// Open + snapshot-only convenience for PR creation (no walk needed,
    /// so the Repository can go out of scope right after this returns --
    /// we capture the OIDs as plain strings).
    private func resolveBranchPair(
        user: String, repo: String, head: String, base: String
    ) throws -> (headOID: String, baseOID: String) {
        try withBranchPair(user: user, repo: repo, head: head, base: base) { pair in
            (headOID: pair.headOID, baseOID: pair.baseOID)
        }
    }

    /// Detect FF status by walking up from `head` looking for `base`.
    /// Bounded BFS (10000 commits) to keep pathological histories sane.
    private static func ffStatus(headOID: String, baseOID: String, headCommit: Commit) -> MergeStatus {
        if headOID == baseOID { return .upToDate }
        var seen: Set<String> = []
        var queue: [Commit] = [headCommit]
        var visited = 0
        while let next = queue.popLast() {
            visited += 1
            if visited > 10_000 { return .diverged }  // bail; treat unreachable
            let oid = next.id.hex
            if oid == baseOID { return .fastForward }
            if !seen.insert(oid).inserted { continue }
            let parents = (try? next.parents) ?? []
            queue.append(contentsOf: parents)
        }
        return .diverged
    }

    private static func validateTitle(_ s: String) throws {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("title is empty")
        }
        guard trimmed.count <= 256 else {
            throw StoreError.invalidInput("title must be <= 256 characters")
        }
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let key = "\(user)/\(repo)"
        if let cached = envelopes[key] { return cached }
        let url = envelopeURL(user: user, repo: repo)
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
            pullRequests: [],
            comments: [],
            nextReactionID: 1,
            reactions: []
        )
        envelopes[key] = env
        return env
    }

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
            .appendingPathComponent("prs.json")
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        envelopes[key] = env
        let url = envelopeURL(user: user, repo: repo)
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
        // Same atomic-ish dance as UserStore / IssueStore (replaceItemAt
        // fatalErrors on swift-corelibs-foundation/Windows).
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("prs.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
