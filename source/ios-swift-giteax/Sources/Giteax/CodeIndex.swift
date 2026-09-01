// hggz/giteax -- Phase 29: FTS5-backed code search index.
//
// Replaces the in-memory tree walk used by CodeSearchRoutes.scan() with
// a persistent SQLite FTS5 index per repo. The previous walker is kept
// as the fallback when the index hasn't been built (or is stale and
// rebuild is in progress).
//
// Per repo:
//   <root>/.giteax/repos/<u>/<r>/code-index.sqlite3
//
// Schema:
//
//   CREATE TABLE meta(
//       key   TEXT PRIMARY KEY,
//       value TEXT NOT NULL
//   );  -- stores indexed_head_oid, indexed_at, file_count
//
//   CREATE VIRTUAL TABLE files_fts USING fts5(
//       path UNINDEXED,
//       oid  UNINDEXED,
//       size UNINDEXED,
//       content,
//       tokenize = 'unicode61 remove_diacritics 2'
//   );
//
// Rebuild policy: lazy. Every search request first asks the index
// whether the current HEAD's commit OID matches indexed_head_oid;
// if not, the search route rebuilds in-band on the requesting thread
// (off the event loop via threadPool.runIfActive). Re-indexes are
// idempotent: drop old rows, re-insert. There's no incremental
// update; the cost is dominated by tree-walk + I/O which we already
// do for the in-memory walker.
//
// Trade-offs vs the in-memory walker:
//   + Single-digit-ms substring queries on tens of thousands of files.
//   + Persistent across server restarts.
//   + snippet() highlighting for free (FTS5 built-in).
//   - One SQLite file per repo. On a deployment with 10000 repos
//     that's 10000 small DBs, which is fine on local disk.
//   - Rebuild on first query after push is O(repo size). For very
//     large pushes the first search may take a second or two. A
//     future optimisation can hook reindex into the post-receive
//     event (Phase 27) for proactive freshness.

import Csqlite3
import Foundation

actor CodeIndex {
    private let rootURL: URL
    private let service: RepositoryService

    /// Open handle cache. Keyed by "user/repo". Reopened on demand.
    private var dbs: [String: OpaquePointer] = [:]

    init(rootURL: URL, service: RepositoryService) {
        self.rootURL = rootURL
        self.service = service
    }

    /// Phase 44: close + drop the cached SQLite handle for `user/repo`.
    /// Required before a repo transfer/rename moves the state dir,
    /// because on Windows an open file handle blocks the move.
    func evictRepo(user: String, repo: String) {
        let key = "\(user)/\(repo)"
        if let h = dbs.removeValue(forKey: key) {
            sqlite3_close_v2(h)
        }
    }

    // Note: no deinit closes the SQLite handles. Swift 6 sendable rules
    // make nonisolated-deinit access to actor properties an error, and
    // the process-exit cleanup is good enough -- SQLite WAL files get
    // checkpointed lazily on next open. If a future change adds a
    // "shutdown" path, expose an `async close()` and call from
    // Application's shutdown lifecycle.

    // MARK: - Public API

    /// Search the repo's index for `query` substrings. If the index is
    /// stale (head OID doesn't match what we last indexed), rebuilds
    /// from scratch before searching. Returns hits + a `usedIndex`
    /// flag so the caller can include diagnostic metadata.
    func search(
        user: String, repo: String,
        query: String,
        limit: Int
    ) throws -> SearchResult {
        let currentHead = try service.summary(user: user, repo: repo).headCommit?.id
        guard let head = currentHead else {
            // Unborn HEAD; no content to index.
            return SearchResult(ref: "(unborn)", count: 0, hits: [], usedIndex: false, indexedAt: nil)
        }
        let db = try ensureOpen(user: user, repo: repo)
        let indexedHead = readMeta(db: db, key: "indexed_head_oid")
        if indexedHead != head {
            try rebuild(db: db, user: user, repo: repo, head: head)
        }

        var hits: [Hit] = []
        var stmt: OpaquePointer?
        // `MATCH` accepts the user's literal token as a single-term query.
        // We escape double-quotes by doubling and wrap in quotes so FTS5
        // treats the whole thing as one phrase. This is the standard
        // FTS5 quoting rule.
        let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
        let matchExpr = "\"\(escaped)\""
        let sql = """
        SELECT path, oid, size,
               snippet(files_fts, 3, '<<', '>>', '…', 24) AS snip
        FROM files_fts
        WHERE files_fts MATCH ?
        ORDER BY bm25(files_fts) ASC
        LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        _ = sqlite3_bind_text(stmt, 1, matchExpr, -1, SQLITE_TRANSIENT)
        _ = sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let oid = String(cString: sqlite3_column_text(stmt, 1))
            let size = Int(sqlite3_column_int(stmt, 2))
            let snip = String(cString: sqlite3_column_text(stmt, 3))
            hits.append(Hit(path: path, oid: oid, size: size, snippet: snip))
        }
        let indexedAt = readMeta(db: db, key: "indexed_at")
        return SearchResult(
            ref: head, count: hits.count, hits: hits,
            usedIndex: true, indexedAt: indexedAt
        )
    }

    // MARK: - Schema + I/O

    private func ensureOpen(user: String, repo: String) throws -> OpaquePointer {
        let key = "\(user)/\(repo)"
        if let existing = dbs[key] { return existing }
        let dbURL = rootURL
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos",   isDirectory: true)
            .appendingPathComponent(user,      isDirectory: true)
            .appendingPathComponent(repo,      isDirectory: true)
            .appendingPathComponent("code-index.sqlite3", isDirectory: false)
        let parent = dbURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let db = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            throw IndexError.openFailed(path: dbURL.path, code: Int(rc))
        }
        // Reasonable defaults for our workload.
        execIgnore(db: db, sql: "PRAGMA journal_mode = WAL;")
        execIgnore(db: db, sql: "PRAGMA synchronous = NORMAL;")
        execIgnore(db: db, sql: "PRAGMA temp_store = MEMORY;")
        // Create schema if missing.
        try exec(db: db, sql: """
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try exec(db: db, sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
            path UNINDEXED,
            oid  UNINDEXED,
            size UNINDEXED,
            content,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
        dbs[key] = db
        return db
    }

    private func rebuild(db: OpaquePointer, user: String, repo: String, head: String) throws {
        // Re-index from scratch. The cost is dominated by libgit2 blob
        // reads + UTF-8 decode; SQLite insert is trivial in comparison.
        try exec(db: db, sql: "BEGIN IMMEDIATE;")
        var didCommit = false
        defer {
            if !didCommit { execIgnore(db: db, sql: "ROLLBACK;") }
        }
        try exec(db: db, sql: "DELETE FROM files_fts;")

        // Tree walk. Same bounds as the in-memory walker (Phase 25).
        var fileCount = 0
        var byteCount = 0
        var stack: [String] = [""]
        guard let resolvedRef = (try? service.summary(user: user, repo: repo).headBranch) else {
            // No default branch -> nothing to index.
            try exec(db: db, sql: "COMMIT;")
            didCommit = true
            return
        }

        var insertStmt: OpaquePointer?
        let insertSQL = "INSERT INTO files_fts(path, oid, size, content) VALUES (?,?,?,?);"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(insertStmt) }

        while let dirPath = stack.popLast() {
            if fileCount >= 50_000 { break }   // safety bound, mirrors walker
            let listing: RepositoryService.TreeListing
            do {
                listing = try service.tree(user: user, repo: repo, ref: resolvedRef, path: dirPath)
            } catch {
                continue
            }
            for entry in listing.entries {
                if fileCount >= 50_000 { break }
                let childPath = dirPath.isEmpty ? entry.name : "\(dirPath)/\(entry.name)"
                switch entry.kind {
                case "tree":
                    stack.append(childPath)
                case "blob", "blobExecutable":
                    if (entry.size ?? 0) > 1_000_000 { continue }   // 1 MiB cap
                    let blobResult: (RepositoryService.BlobInfo, Data)
                    do {
                        blobResult = try service.blob(user: user, repo: repo, ref: resolvedRef, path: childPath)
                    } catch {
                        continue
                    }
                    let (info, data) = blobResult
                    if info.isBinary { continue }
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    sqlite3_reset(insertStmt)
                    sqlite3_bind_text(insertStmt, 1, childPath, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 2, info.oid, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 3, Int32(info.size))
                    sqlite3_bind_text(insertStmt, 4, text, -1, SQLITE_TRANSIENT)
                    let rc = sqlite3_step(insertStmt)
                    if rc != SQLITE_DONE {
                        throw IndexError.queryFailed(message: "fts insert: \(String(cString: sqlite3_errmsg(db)))")
                    }
                    fileCount += 1
                    byteCount += data.count
                default:
                    continue
                }
            }
        }

        // Update meta.
        try writeMeta(db: db, key: "indexed_head_oid", value: head)
        try writeMeta(db: db, key: "indexed_at", value: ISO8601DateFormatter().string(from: Date()))
        try writeMeta(db: db, key: "file_count", value: String(fileCount))
        try writeMeta(db: db, key: "byte_count", value: String(byteCount))

        try exec(db: db, sql: "COMMIT;")
        didCommit = true
    }

    private func readMeta(db: OpaquePointer, key: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private func writeMeta(db: OpaquePointer, key: String, value: String) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw IndexError.queryFailed(message: "meta write: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func exec(db: OpaquePointer, sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "code=\(rc)"
            if err != nil { sqlite3_free(err) }
            throw IndexError.queryFailed(message: "exec: \(msg)")
        }
    }

    private func execIgnore(db: OpaquePointer, sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Types

    struct Hit: Sendable, Codable {
        let path: String
        let oid: String
        let size: Int
        let snippet: String
    }

    struct SearchResult: Sendable {
        let ref: String
        let count: Int
        let hits: [Hit]
        let usedIndex: Bool
        let indexedAt: String?
    }

    enum IndexError: Error, CustomStringConvertible {
        case openFailed(path: String, code: Int)
        case queryFailed(message: String)
        var description: String {
            switch self {
            case .openFailed(let p, let c): "open \(p) failed (code=\(c))"
            case .queryFailed(let m):       "query failed: \(m)"
            }
        }
    }
}

// MARK: - SQLite transient destructor (Swift can't import the C macro)

/// `SQLITE_TRANSIENT` from C is `((sqlite3_destructor_type)-1)`; Swift's
/// importer can't translate that. Reconstruct it by bit-casting -1 to a
/// destructor pointer. Same trick used in HermesAgentSwift's Csqlite3
/// bridge (see swift-sqlite-cross-platform memory note).
let SQLITE_TRANSIENT = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
