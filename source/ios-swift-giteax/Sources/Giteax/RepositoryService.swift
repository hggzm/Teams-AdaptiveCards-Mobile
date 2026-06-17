import Foundation
import SwiftGitX
import Vapor

/// Lookup + read-only inspection of bare or working-tree repositories on
/// disk, rooted at a single base directory.
///
/// Layout convention (matches Gitea's storage shape):
///
///     <root>/<user>/<repo>.git    (bare repo)
///     <root>/<user>/<repo>        (working-tree fallback if .git form missing)
///
/// `<root>` is set at startup from the `GITEAX_ROOT` env var, falling back
/// to `./repos` when unset.
///
/// All methods are blocking libgit2 calls; route handlers should hop them
/// off the event loop (the routes in `main.swift` do this via a
/// `Vapor.Application.threadPool.runIfActive` wrapper).
struct RepositoryService: Sendable {
    let root: URL

    /// Errors that map cleanly to HTTP status codes for route handlers.
    enum LookupError: Error, AbortError {
        case invalidName(String)
        case notFound(user: String, repo: String)
        case openFailed(user: String, repo: String, underlying: String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidName:   .badRequest
            case .notFound:      .notFound
            case .openFailed:    .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .invalidName(let n):
                return "invalid repo path segment: '\(n)'"
            case .notFound(let user, let repo):
                return "no repository at \(user)/\(repo)"
            case .openFailed(let user, let repo, let underlying):
                return "failed to open \(user)/\(repo): \(underlying)"
            }
        }
    }

    /// Snapshot of the public-facing repo summary used by `GET /:user/:repo`.
    struct Summary: Sendable {
        let user: String
        let repo: String
        let isBare: Bool
        let isEmpty: Bool
        let isHEADDetached: Bool
        let isHEADUnborn: Bool
        let headBranch: String?
        let headCommit: CommitInfo?
        let branchCount: Int
        let branches: [String]
    }

    /// Cut-down commit projection used by both summary and log routes. Keeps
    /// the wire shape stable independent of SwiftGitX's internal Commit type.
    struct CommitInfo: Sendable, Codable {
        let id: String
        let summary: String
        let authorName: String
        let authorEmail: String
        let date: Date
    }

    /// One row in a directory listing for `GET /:user/:repo/tree/:ref/*`.
    struct TreeEntry: Sendable, Codable {
        /// Filename (basename only -- never contains slashes).
        let name: String
        /// "tree", "blob", "blobExecutable", "symlink", or "commit" (submodule).
        let kind: String
        /// Octal file mode as a string (e.g. "100644"). Stable wire shape.
        let mode: String
        /// SHA-1 hex of the entry's target object.
        let oid: String
        /// Byte size for blobs only; nil otherwise.
        let size: Int?
    }

    /// Listing payload for `GET /:user/:repo/tree/:ref/<path>`.
    struct TreeListing: Sendable, Codable {
        let user: String
        let repo: String
        let ref: String
        let path: String
        let entries: [TreeEntry]
    }

    /// Blob payload metadata used by `GET /:user/:repo/blob/:ref/<path>`.
    /// `data` is returned separately by `blob(...)` to avoid forcing a Codable
    /// round trip through Data when streaming.
    struct BlobInfo: Sendable {
        let user: String
        let repo: String
        let ref: String
        let path: String
        let oid: String
        let size: Int
        let isBinary: Bool
        /// File-mode flavor for clients that care: "blob", "blobExecutable",
        /// or "symlink". Plain file otherwise.
        let kind: String
    }

    // MARK: - Phase 5 diff types

    /// Per-file summary of a ref-to-ref diff. Wire-stable shape; we deliberately
    /// don't expose libgit2's raw flag bit layout.
    struct DiffFile: Sendable, Codable {
        /// "added", "deleted", "modified", "renamed", "copied", "typeChange",
        /// "ignored", "untracked", "unreadable", "conflicted", or "unmodified".
        let status: String
        /// Path in the *old* tree (nil when this is a pure add).
        let oldPath: String?
        /// Path in the *new* tree (nil when this is a pure delete).
        let newPath: String?
        /// Old-side blob OID (zero-OID when the file didn't exist before).
        let oldOid: String?
        /// New-side blob OID (zero-OID when the file no longer exists).
        let newOid: String?
        /// Similarity score 0-100 for renamed/copied files (nil otherwise).
        let similarity: Int?
        /// True when libgit2 marked either side as binary.
        let isBinary: Bool
        /// Hunks with line-level changes; nil when libgit2 couldn't (or
        /// wouldn't, for binary files) produce a textual patch.
        let hunks: [DiffHunk]?
    }

    /// One contiguous block of changes within a file.
    struct DiffHunk: Sendable, Codable {
        let header: String
        let oldStart: Int
        let oldLines: Int
        let newStart: Int
        let newLines: Int
        let lines: [DiffLine]
    }

    /// One line of context, addition, or deletion within a hunk.
    struct DiffLine: Sendable, Codable {
        /// "context", "addition", "deletion", "contextEOF", "additionEOF",
        /// or "deletionEOF" (the *EOF variants flag missing trailing newlines).
        let kind: String
        let content: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

    /// Aggregated diff payload returned by `GET /:user/:repo/diff/:base/:head`.
    struct DiffResult: Sendable, Codable {
        let user: String
        let repo: String
        let base: String
        let head: String
        let baseCommit: String
        let headCommit: String
        let fileCount: Int
        let files: [DiffFile]
    }

    // MARK: - Init

    init(root: URL) {
        self.root = root
    }

    // MARK: - Path resolution

    /// Validates a `user`/`repo` path segment. Refuses anything that could
    /// climb out of `root` (`..`, slash, drive letters) or that contains
    /// platform-illegal characters. The allowed grammar matches what Gitea
    /// accepts for org+repo names: `[A-Za-z0-9][A-Za-z0-9._-]*`.
    static func validateSegment(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100 else { return false }
        // Reject path-traversal / namespace games early.
        if s.contains("/") || s.contains("\\") || s == "." || s == ".." {
            return false
        }
        // Must start with alphanumeric, then allow `.` `_` `-`.
        let first = s.unicodeScalars.first!
        if !(("A"..."Z").contains(first) ||
             ("a"..."z").contains(first) ||
             ("0"..."9").contains(first)) { return false }
        for sc in s.unicodeScalars.dropFirst() {
            let isAlpha = ("A"..."Z").contains(sc) || ("a"..."z").contains(sc)
            let isDigit = ("0"..."9").contains(sc)
            let isAllowed = sc == "." || sc == "_" || sc == "-"
            if !(isAlpha || isDigit || isAllowed) { return false }
        }
        return true
    }

    /// Returns the on-disk URL for `<root>/<user>/<repo>.git` if that
    /// directory exists, otherwise `<root>/<user>/<repo>` if that exists,
    /// otherwise nil.
    func locate(user: String, repo: String) -> URL? {
        let bare = root.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) {
            return bare
        }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        if FileManager.default.fileExists(atPath: working.path) {
            return working
        }
        return nil
    }

    // MARK: - Operations

    /// Open a Repository for read-only inspection. Throws LookupError on
    /// invalid input or missing repo. The returned Repository must NOT
    /// escape the closure -- libgit2 ownership semantics make leaking it
    /// across thread boundaries risky.
    func open(user: String, repo: String) throws -> Repository {
        guard Self.validateSegment(user), Self.validateSegment(repo) else {
            throw LookupError.invalidName("\(user)/\(repo)")
        }
        guard let url = locate(user: user, repo: repo) else {
            throw LookupError.notFound(user: user, repo: repo)
        }
        do {
            return try Repository.open(at: url)
        } catch {
            throw LookupError.openFailed(
                user: user, repo: repo,
                underlying: String(describing: error)
            )
        }
    }

    /// Build a Summary for `GET /:user/:repo`. Blocking; offload via threadPool.
    func summary(user: String, repo: String) throws -> Summary {
        let r = try open(user: user, repo: repo)
        let unborn = r.isHEADUnborn
        let detached = r.isHEADDetached
        let bare = r.isBare
        let isEmpty = r.isEmpty

        // Branch list. SwiftGitX returns BranchType.all union by default.
        let branches = (try? r.branch.list()) ?? []
        let names = branches.map(\.name).sorted()

        var headBranchName: String? = nil
        var headCommit: CommitInfo? = nil
        if !unborn {
            let head = try r.HEAD
            if !detached { headBranchName = head.name }
            if let commit = head.target as? Commit {
                headCommit = CommitInfo(
                    id: commit.id.hex,
                    summary: commit.summary,
                    authorName: commit.author.name,
                    authorEmail: commit.author.email,
                    date: commit.date
                )
            }
        }

        return Summary(
            user: user,
            repo: repo,
            isBare: bare,
            isEmpty: isEmpty,
            isHEADDetached: detached,
            isHEADUnborn: unborn,
            headBranch: headBranchName,
            headCommit: headCommit,
            branchCount: branches.count,
            branches: names
        )
    }

    /// Phase 20: snapshot `{ ref-name -> oid hex }` for every branch in
    /// the repo. Used by the smart-HTTP push handler to compute a before/
    /// after diff and emit a richer `push` webhook payload. Blocking.
    func refSnapshot(user: String, repo: String) throws -> [String: String] {
        let r = try open(user: user, repo: repo)
        let branches = (try? r.branch.list()) ?? []
        var out: [String: String] = [:]
        for b in branches {
            if let commit = b.target as? Commit {
                out[b.name] = commit.id.hex
            }
        }
        return out
    }

    /// Paginated commit log for `GET /:user/:repo/commits/:ref`. Blocking.
    ///
    /// `ref` follows the grammar described on `resolveCommit(...)`: HEAD,
    /// a 40-char OID hex, a branch name, or a tag name.
    func log(user: String, repo: String, ref: String, limit: Int) throws -> [CommitInfo] {
        let r = try open(user: user, repo: repo)
        let startCommit = try resolveCommit(in: r, ref: ref, user: user, repo: repo)
        // `log(from: Commit, ...)` is non-throwing on SwiftGitX 0.4.0; the
        // walker creation only throws when libgit2 itself errors, which would
        // surface via the `seq.makeIterator().next()` returning nil rather
        // than a Swift error. Keep the throwing wrap in case that changes.
        let seq = r.log(from: startCommit, sorting: .topological)

        var out: [CommitInfo] = []
        out.reserveCapacity(min(limit, 256))
        let iter = seq.makeIterator()
        while out.count < limit, let c = iter.next() {
            out.append(CommitInfo(
                id: c.id.hex,
                summary: c.summary,
                authorName: c.author.name,
                authorEmail: c.author.email,
                date: c.date
            ))
        }
        return out
    }

    /// Phase 54: contributor row aggregated from a walked log.
    struct ContributorRow: Codable, Sendable {
        let name: String
        let email: String
        let commits: Int
    }

    /// Phase 55: branch row with HEAD commit metadata.
    struct BranchRow: Codable, Sendable {
        let name: String
        let isDefault: Bool
        let commit: CommitInfo
    }

    /// Phase 55: list branches with HEAD commit info. Sorted by name
    /// ascending, with the default branch (if known) hoisted to the front.
    func branches(user: String, repo: String, defaultBranch: String?) throws -> [BranchRow] {
        let r = try open(user: user, repo: repo)
        let raw = (try? r.branch.list()) ?? []
        var rows: [BranchRow] = []
        rows.reserveCapacity(raw.count)
        for b in raw {
            guard let commit = b.target as? Commit else { continue }
            rows.append(BranchRow(
                name: b.name,
                isDefault: defaultBranch != nil && b.name == defaultBranch,
                commit: CommitInfo(
                    id: commit.id.hex,
                    summary: commit.summary,
                    authorName: commit.author.name,
                    authorEmail: commit.author.email,
                    date: commit.date
                )
            ))
        }
        rows.sort { (a, b) in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name < b.name
        }
        return rows
    }

    /// Phase 55: single branch lookup. Returns nil if absent.
    func branch(user: String, repo: String, name: String, defaultBranch: String?) throws -> BranchRow? {
        let r = try open(user: user, repo: repo)
        guard let b = try? r.branch.get(named: name),
              let commit = b.target as? Commit
        else { return nil }
        return BranchRow(
            name: b.name,
            isDefault: defaultBranch != nil && b.name == defaultBranch,
            commit: CommitInfo(
                id: commit.id.hex,
                summary: commit.summary,
                authorName: commit.author.name,
                authorEmail: commit.author.email,
                date: commit.date
            )
        )
    }

    /// Phase 54: contributor list aggregated by walking commits reachable
    /// from `ref` (defaults to HEAD). Bounded BFS-equivalent via the
    /// SwiftGitX log iterator so pathological histories don't hang the
    /// thread. Group key is `"<name> <email>"` lower-cased; the row
    /// keeps the first-seen casing. Sorted by descending commit count,
    /// then ascending lower-cased name.
    func contributors(
        user: String, repo: String,
        ref: String = "HEAD",
        maxCommits: Int = 10_000,
        limit: Int = 100
    ) throws -> [ContributorRow] {
        let r = try open(user: user, repo: repo)
        // Empty / unborn repo -> no contributors, not an error.
        if r.isHEADUnborn { return [] }
        let startCommit: Commit
        do {
            startCommit = try resolveCommit(in: r, ref: ref, user: user, repo: repo)
        }
        let seq = r.log(from: startCommit, sorting: .topological)
        var counts: [String: (name: String, email: String, commits: Int)] = [:]
        var visited = 0
        let iter = seq.makeIterator()
        while visited < maxCommits, let c = iter.next() {
            visited += 1
            let name = c.author.name
            let email = c.author.email
            let key = (name + " " + email).lowercased()
            if var existing = counts[key] {
                existing.commits += 1
                counts[key] = existing
            } else {
                counts[key] = (name: name, email: email, commits: 1)
            }
        }
        let rows = counts.values
            .map { ContributorRow(name: $0.name, email: $0.email, commits: $0.commits) }
            .sorted {
                if $0.commits != $1.commits { return $0.commits > $1.commits }
                return $0.name.lowercased() < $1.name.lowercased()
            }
        return Array(rows.prefix(max(0, limit)))
    }

    /// Directory listing at `<path>` for ref `<ref>` in `<user>/<repo>`.
    /// An empty `path` returns the repository root tree.
    func tree(user: String, repo: String, ref: String, path: String) throws -> TreeListing {
        let r = try open(user: user, repo: repo)
        let commit = try resolveCommit(in: r, ref: ref, user: user, repo: repo)
        let rootTree: Tree
        do { rootTree = try commit.tree }
        catch {
            throw LookupError.openFailed(user: user, repo: repo,
                                         underlying: "load root tree: \(error)")
        }

        let components = Self.splitPath(path)
        let leaf: Tree
        do {
            leaf = try Self.walkTree(rootTree, components: components, in: r)
        } catch let e as LookupError { throw e }
        catch {
            throw LookupError.openFailed(user: user, repo: repo,
                                         underlying: "walk \(path): \(error)")
        }

        var rows: [TreeEntry] = []
        rows.reserveCapacity(leaf.entries.count)
        for e in leaf.entries {
            let kind = Self.kindString(for: e.type, mode: e.mode)
            var size: Int? = nil
            if e.type == .blob {
                if let blob: Blob = try? r.show(id: e.id) {
                    size = blob.content.count
                }
            }
            rows.append(TreeEntry(
                name: e.name,
                kind: kind,
                mode: String(e.mode.rawValue, radix: 8),
                oid: e.id.hex,
                size: size
            ))
        }
        // Stable sort: trees first, then blobs, alphabetic within each.
        rows.sort { lhs, rhs in
            let lt = lhs.kind == "tree"
            let rt = rhs.kind == "tree"
            if lt != rt { return lt && !rt }
            return lhs.name < rhs.name
        }
        return TreeListing(
            user: user, repo: repo, ref: ref,
            path: Self.normalizedPath(components),
            entries: rows
        )
    }

    /// Fetch the blob at `<path>` for ref `<ref>` in `<user>/<repo>`.
    /// Returns the metadata + raw bytes. Route layer decides streaming vs
    /// inline.
    func blob(user: String, repo: String, ref: String, path: String) throws -> (BlobInfo, Data) {
        let r = try open(user: user, repo: repo)
        let commit = try resolveCommit(in: r, ref: ref, user: user, repo: repo)
        let rootTree: Tree
        do { rootTree = try commit.tree }
        catch {
            throw LookupError.openFailed(user: user, repo: repo,
                                         underlying: "load root tree: \(error)")
        }

        let components = Self.splitPath(path)
        guard let last = components.last else {
            throw LookupError.invalidName("(empty blob path)")
        }
        let parentTree: Tree
        do {
            parentTree = try Self.walkTree(rootTree, components: Array(components.dropLast()), in: r)
        } catch let e as LookupError { throw e }
        catch {
            throw LookupError.openFailed(user: user, repo: repo,
                                         underlying: "walk parent of \(path): \(error)")
        }
        guard let entry = parentTree.entries.first(where: { $0.name == last }) else {
            throw LookupError.notFound(user: user, repo: "\(repo)@\(ref):\(path)")
        }
        guard entry.type == .blob else {
            throw LookupError.openFailed(user: user, repo: repo,
                                         underlying: "\(path) is a \(entry.type) not a blob")
        }
        let blob: Blob
        do { blob = try r.show(id: entry.id) }
        catch {
            throw LookupError.openFailed(user: user, repo: repo,
                                         underlying: "load blob \(entry.id.hex): \(error)")
        }
        let info = BlobInfo(
            user: user, repo: repo, ref: ref,
            path: Self.normalizedPath(components),
            oid: blob.id.hex,
            size: blob.content.count,
            isBinary: Self.looksBinary(blob.content),
            kind: Self.kindString(for: .blob, mode: entry.mode)
        )
        return (info, blob.content)
    }

    /// Ref-to-ref diff for `GET /:user/:repo/diff/:base/:head`. Blocking.
    /// Both `base` and `head` follow the same grammar as `:ref` elsewhere
    /// (a branch name or `HEAD`). Returns per-file deltas with optional
    /// hunk arrays.
    func diff(user: String, repo: String,
              base: String, head: String) throws -> DiffResult {
        let r = try open(user: user, repo: repo)
        let baseCommit = try resolveCommit(in: r, ref: base, user: user, repo: repo)
        let headCommit = try resolveCommit(in: r, ref: head, user: user, repo: repo)

        let d: Diff
        do {
            d = try r.diff(from: baseCommit, to: headCommit)
        } catch {
            throw LookupError.openFailed(
                user: user, repo: repo,
                underlying: "diff \(base)..\(head): \(error)"
            )
        }

        // Build a path -> patch index so we can attach hunk data per change.
        var patchByPath: [String: Patch] = [:]
        patchByPath.reserveCapacity(d.patches.count)
        for p in d.patches {
            // Match patches to deltas by new-side path first, fall back to old
            // when this is a pure delete.
            let key = p.delta.newFile.path.isEmpty ? p.delta.oldFile.path : p.delta.newFile.path
            patchByPath[key] = p
        }

        var files: [DiffFile] = []
        files.reserveCapacity(d.changes.count)
        for change in d.changes {
            let oldPath = change.oldFile.path.isEmpty ? nil : change.oldFile.path
            let newPath = change.newFile.path.isEmpty ? nil : change.newFile.path
            let key = newPath ?? oldPath ?? ""
            let patch = patchByPath[key]

            // libgit2 marks binary-ness via .binary flag on the Delta.
            let isBinary = change.flags.contains(.binary)

            let hunks: [DiffHunk]?
            if let patch, !isBinary {
                hunks = patch.hunks.map { Self.makeHunk($0) }
            } else {
                hunks = nil
            }

            files.append(DiffFile(
                status: Self.deltaStatusString(change.type),
                oldPath: oldPath,
                newPath: newPath,
                oldOid: Self.oidOrNil(change.oldFile.id),
                newOid: Self.oidOrNil(change.newFile.id),
                similarity: (change.type == .renamed || change.type == .copied)
                    ? change.similarity : nil,
                isBinary: isBinary,
                hunks: hunks
            ))
        }
        // Stable ordering: by new path (alphabetical), then old path.
        files.sort { lhs, rhs in
            let l = lhs.newPath ?? lhs.oldPath ?? ""
            let r = rhs.newPath ?? rhs.oldPath ?? ""
            return l < r
        }

        return DiffResult(
            user: user, repo: repo,
            base: base, head: head,
            baseCommit: baseCommit.id.hex,
            headCommit: headCommit.id.hex,
            fileCount: files.count,
            files: files
        )
    }

    // MARK: - Internal helpers

    /// Resolve a textual ref ("HEAD" or a branch name) to a SwiftGitX
    /// Reference. Used only by `summary(...)` which needs the reference's
    /// `.name` to surface the branch display. Other callers should use
    /// `resolveCommit(...)` directly.
    private func resolveRef(in r: Repository, ref: String,
                            user: String, repo: String) throws -> any Reference {
        if ref == "HEAD" {
            return try r.HEAD
        }
        guard Self.validateSegment(ref) else {
            throw LookupError.invalidName(ref)
        }
        do {
            return try r.branch.get(named: ref)
        } catch {
            throw LookupError.notFound(user: user, repo: "\(repo)@\(ref)")
        }
    }

    /// Resolve a textual ref to the underlying Commit.
    ///
    /// Phase 6 grammar (in resolution order):
    ///   1. `"HEAD"` (case-sensitive) -> the current HEAD commit
    ///   2. a 40-char hex string matching `[0-9a-fA-F]{40}` -> looked up
    ///      directly as a Commit OID via `Repository.show<Commit>(id:)`.
    ///      Short OIDs (less than 40 chars) are NOT supported: SwiftGitX
    ///      doesn't expose `git_object_lookup_prefix`, and shipping a
    ///      brute-force prefix walk would be a footgun for big repos.
    ///   3. a name segment (`[A-Za-z0-9][A-Za-z0-9._-]*`, ≤100 chars)
    ///      tried as a branch first, then as a tag (annotated or
    ///      lightweight). Tag targets are peeled to Commit; tag-of-tag
    ///      chains aren't followed (rare; deferred to a later phase).
    ///
    /// Throws `LookupError.invalidName` for grammar violations and
    /// `LookupError.notFound` when nothing matches.
    private func resolveCommit(in r: Repository, ref: String,
                               user: String, repo: String) throws -> Commit {
        // 1. HEAD
        if ref == "HEAD" {
            guard let commit = (try r.HEAD.target) as? Commit else {
                throw LookupError.openFailed(
                    user: user, repo: repo,
                    underlying: "HEAD does not peel to a commit"
                )
            }
            return commit
        }

        // 2. Full 40-char OID hex
        if Self.isFullOIDHex(ref) {
            do {
                let oid = try OID(hex: ref)
                let commit: Commit = try r.show(id: oid)
                return commit
            } catch {
                throw LookupError.notFound(user: user, repo: "\(repo)@\(ref)")
            }
        }

        // 3. Branch then tag
        guard Self.validateSegment(ref) else {
            throw LookupError.invalidName(ref)
        }
        if let branch = try? r.branch.get(named: ref),
           let commit = branch.target as? Commit {
            return commit
        }
        if let tag = try? r.tag.get(named: ref),
           let commit = tag.target as? Commit {
            return commit
        }
        throw LookupError.notFound(user: user, repo: "\(repo)@\(ref)")
    }

    /// True iff `s` is exactly 40 ASCII hex characters (case-insensitive).
    static func isFullOIDHex(_ s: String) -> Bool {
        guard s.count == 40 else { return false }
        for sc in s.unicodeScalars {
            let isDigit = ("0"..."9").contains(sc)
            let isLower = ("a"..."f").contains(sc)
            let isUpper = ("A"..."F").contains(sc)
            if !(isDigit || isLower || isUpper) { return false }
        }
        return true
    }

    /// Split a slash-delimited path into clean components, rejecting empties
    /// and `..` segments at the boundary. Same idea as path-segment validation
    /// applied per-component, but with a slightly looser char class because
    /// real filenames legitimately contain non-identifier chars.
    static func splitPath(_ raw: String) -> [String] {
        raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func normalizedPath(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    /// Descend through `tree` along the given path components, returning the
    /// final subtree. Empty `components` returns the input unchanged.
    private static func walkTree(_ tree: Tree, components: [String],
                                 in r: Repository) throws -> Tree {
        var current = tree
        for comp in components {
            // Reject path-traversal at the per-component level too.
            if comp == ".." || comp == "." || comp.contains("\\") {
                throw LookupError.invalidName(comp)
            }
            guard let entry = current.entries.first(where: { $0.name == comp }) else {
                throw LookupError.notFound(user: "(walk)", repo: comp)
            }
            guard entry.type == .tree else {
                throw LookupError.openFailed(
                    user: "(walk)", repo: comp,
                    underlying: "expected a tree, got \(entry.type)"
                )
            }
            do {
                current = try r.show(id: entry.id)
            } catch {
                throw LookupError.openFailed(
                    user: "(walk)", repo: comp,
                    underlying: "load subtree: \(error)"
                )
            }
        }
        return current
    }

    /// Map (ObjectType, FileMode) to a stable wire-shape string.
    private static func kindString(for type: ObjectType, mode: FileMode) -> String {
        switch type {
        case .tree:   return "tree"
        case .commit: return "commit" // submodule pointer
        case .blob:
            switch mode {
            case .blobExecutable: return "blobExecutable"
            case .symlink:        return "symlink"
            default:              return "blob"
            }
        case .tag:     return "tag"
        case .any, .invalid:
            return "blob"
        }
    }

    /// Cheap binary heuristic: any NUL byte in the first 8 KB → binary.
    /// Matches what git itself uses for diff/blame heuristics.
    private static func looksBinary(_ data: Data) -> Bool {
        let window = data.prefix(8 * 1024)
        return window.contains(0)
    }

    // MARK: - Diff helpers (Phase 5)

    /// Convert SwiftGitX's `Diff.DeltaType` to the wire-stable string we ship.
    private static func deltaStatusString(_ t: Diff.DeltaType) -> String {
        switch t {
        case .unmodified: return "unmodified"
        case .added:      return "added"
        case .deleted:    return "deleted"
        case .modified:   return "modified"
        case .renamed:    return "renamed"
        case .copied:     return "copied"
        case .ignored:    return "ignored"
        case .untracked:  return "untracked"
        case .typeChange: return "typeChange"
        case .unreadable: return "unreadable"
        case .conflicted: return "conflicted"
        }
    }

    /// SwiftGitX uses an all-zeros OID to mean "no file on this side". The
    /// wire shape should expose that as nil; everything else is a real hex id.
    private static let zeroOIDHex = String(repeating: "0", count: 40)
    private static func oidOrNil(_ oid: OID) -> String? {
        let h = oid.hex
        return h == zeroOIDHex ? nil : h
    }

    /// Translate a SwiftGitX Patch.Hunk to the Codable DiffHunk wire shape.
    private static func makeHunk(_ h: Patch.Hunk) -> DiffHunk {
        let lines = h.lines.map { l -> DiffLine in
            // SwiftGitX collapses old+new line numbers down to a single
            // `lineNumber` (whichever isn't -1). We can recover the split
            // from the line kind: deletions only have an old line number,
            // additions only have a new line number, contexts have both
            // (we pick "same line number on both sides" as a reasonable
            // approximation -- libgit2's git_diff_line struct itself
            // exposes the dual numbers, but SwiftGitX hides them).
            let kind = Self.lineKindString(l.type)
            switch l.type {
            case .addition, .additionEOF:
                return DiffLine(kind: kind, content: l.content,
                                oldLineNumber: nil, newLineNumber: l.lineNumber)
            case .deletion, .deletionEOF:
                return DiffLine(kind: kind, content: l.content,
                                oldLineNumber: l.lineNumber, newLineNumber: nil)
            case .context, .contextEOF:
                return DiffLine(kind: kind, content: l.content,
                                oldLineNumber: l.lineNumber,
                                newLineNumber: l.lineNumber)
            }
        }
        return DiffHunk(
            header: h.header,
            oldStart: h.oldStart, oldLines: h.oldLines,
            newStart: h.newStart, newLines: h.newLines,
            lines: lines
        )
    }

    private static func lineKindString(_ t: Patch.Hunk.LineType) -> String {
        switch t {
        case .context:      return "context"
        case .addition:     return "addition"
        case .deletion:     return "deletion"
        case .contextEOF:   return "contextEOF"
        case .additionEOF:  return "additionEOF"
        case .deletionEOF:  return "deletionEOF"
        }
    }
}
