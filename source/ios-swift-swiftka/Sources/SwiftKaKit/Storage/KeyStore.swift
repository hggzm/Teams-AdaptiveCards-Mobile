import Csqlite3
import Foundation

/// Implements the Phase 5 key-management surface:
/// `SET` / `GET` / `DEL` / `EXISTS` / `KEYS` / `TYPE` / `RENAME`.
///
/// All operations go through the parent ``Database`` so they share the
/// same SQLite connection (serialised by ``Database/withLock``). State
/// lives in the redka-byte-identical `rkey` + `rstring` tables.
public final class KeyStore: @unchecked Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Current wall-clock in milliseconds since epoch — the unit redka
    /// uses for `rkey.mtime` and `rkey.etime`.
    private static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - SET

    /// Plain `SET key value`. Overwrites any existing value (and the
    /// type, which becomes `string`). TTL handling lands in a later
    /// phase; for now any pre-existing etime is cleared.
    public func set(key: String, value: Data) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                try upsertKey(conn: conn, key: key, type: .string)
                let kid = try fetchKid(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, value)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - GET

    /// Returns the value for a string key, or `nil` if missing or
    /// expired. Returns an error if the key holds a non-string type.
    public func get(key: String) throws -> Data? {
        try database.withLock { conn in
            // SELECT joins rkey to filter out expired entries and to
            // surface a type mismatch as an error.
            let rows: [(Int32, Data)] = try conn.run(
                """
                SELECT rkey.type, rstring.value
                FROM rstring JOIN rkey ON rstring.kid = rkey.id
                WHERE rkey.key = ?
                  AND (rkey.etime IS NULL OR rkey.etime > ?)
                """,
                bind: { stmt in
                    SQLiteConnection.bindText(stmt, 1, key)
                    SQLiteConnection.bindInt64(stmt, 2, Self.nowMS())
                },
                rowMap: { stmt in
                    (Int32(SQLiteConnection.columnInt64(stmt, 0)),
                     SQLiteConnection.columnBlob(stmt, 1))
                }
            )
            guard let (t, value) = rows.first else { return nil }
            if t != RedkaType.string.rawValue {
                throw KeyStoreError.wrongType
            }
            return value
        }
    }

    // MARK: - DEL

    /// Deletes one or more keys; returns the number actually removed.
    public func del(keys: [String]) throws -> Int {
        try database.withLock { conn in
            var removed = 0
            try conn.exec("BEGIN IMMEDIATE")
            do {
                for key in keys {
                    try conn.run(
                        "DELETE FROM rkey WHERE key = ?",
                        bind: { stmt in SQLiteConnection.bindText(stmt, 1, key) },
                        rowMap: { _ in () }
                    )
                    removed += conn.changes()
                }
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
            return removed
        }
    }

    // MARK: - EXISTS

    /// Counts how many of the given keys exist (duplicates count
    /// multiple times, matching Redis semantics).
    public func exists(keys: [String]) throws -> Int {
        try database.withLock { conn in
            var total = 0
            for key in keys {
                let rows: [Int64] = try conn.run(
                    """
                    SELECT 1 FROM rkey
                    WHERE key = ?
                      AND (etime IS NULL OR etime > ?)
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMS())
                    },
                    rowMap: { _ in 1 }
                )
                total += rows.count
            }
            return total
        }
    }

    // MARK: - KEYS

    /// Returns all keys matching a glob pattern (`*`, `?`, `[abc]`).
    /// The pattern is translated to a Swift regex; SQL `LIKE` is too
    /// limited (no `?`, no `[]`).
    public func keys(pattern: String) throws -> [String] {
        let regex = try Self.compileGlob(pattern)
        return try database.withLock { conn in
            let rows: [String] = try conn.run(
                """
                SELECT key FROM rkey
                WHERE (etime IS NULL OR etime > ?)
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, Self.nowMS())
                },
                rowMap: { stmt in SQLiteConnection.columnText(stmt, 0) }
            )
            return rows.filter { regex.firstMatch(in: $0,
                                                  range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        }
    }

    // MARK: - TYPE

    /// Returns the wire-level type name (`"string"`, `"list"`, …) or
    /// `"none"` if the key does not exist.
    public func type(key: String) throws -> String {
        try database.withLock { conn in
            let rows: [Int32] = try conn.run(
                """
                SELECT type FROM rkey
                WHERE key = ?
                  AND (etime IS NULL OR etime > ?)
                """,
                bind: { stmt in
                    SQLiteConnection.bindText(stmt, 1, key)
                    SQLiteConnection.bindInt64(stmt, 2, Self.nowMS())
                },
                rowMap: { stmt in Int32(SQLiteConnection.columnInt64(stmt, 0)) }
            )
            guard let raw = rows.first,
                  let t = RedkaType(rawValue: raw) else { return "none" }
            return t.wireName
        }
    }

    // MARK: - RENAME

    /// Renames `src` to `dst`. If `dst` already exists it is replaced.
    /// Throws ``KeyStoreError/noSuchKey`` if `src` is missing or
    /// expired.
    public func rename(src: String, dst: String) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let exists: [Int64] = try conn.run(
                    """
                    SELECT 1 FROM rkey
                    WHERE key = ?
                      AND (etime IS NULL OR etime > ?)
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, src)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMS())
                    },
                    rowMap: { _ in 1 }
                )
                guard !exists.isEmpty else {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.noSuchKey
                }
                if src != dst {
                    // Drop any existing dst, then rename src.
                    try conn.run(
                        "DELETE FROM rkey WHERE key = ?",
                        bind: { stmt in SQLiteConnection.bindText(stmt, 1, dst) },
                        rowMap: { _ in () }
                    )
                    try conn.run(
                        "UPDATE rkey SET key = ?, mtime = ?, version = version + 1 WHERE key = ?",
                        bind: { stmt in
                            SQLiteConnection.bindText(stmt, 1, dst)
                            SQLiteConnection.bindInt64(stmt, 2, Self.nowMS())
                            SQLiteConnection.bindText(stmt, 3, src)
                        },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - Helpers

    private func upsertKey(conn: SQLiteConnection, key: String, type: RedkaType) throws {
        let now = Self.nowMS()
        try conn.run(
            """
            INSERT INTO rkey (key, type, version, etime, mtime, len)
            VALUES (?, ?, 1, NULL, ?, NULL)
            ON CONFLICT(key) DO UPDATE SET
                type    = excluded.type,
                version = rkey.version + 1,
                etime   = NULL,
                mtime   = excluded.mtime
            """,
            bind: { stmt in
                SQLiteConnection.bindText(stmt, 1, key)
                SQLiteConnection.bindInt64(stmt, 2, Int64(type.rawValue))
                SQLiteConnection.bindInt64(stmt, 3, now)
            },
            rowMap: { _ in () }
        )
    }

    private func fetchKid(conn: SQLiteConnection, key: String) throws -> Int64 {
        let rows: [Int64] = try conn.run(
            "SELECT id FROM rkey WHERE key = ?",
            bind: { stmt in SQLiteConnection.bindText(stmt, 1, key) },
            rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
        )
        guard let id = rows.first else {
            throw KeyStoreError.noSuchKey
        }
        return id
    }

    /// Translates a Redis-style glob (`*`, `?`, `[abc]`, `\` escapes)
    /// to an `NSRegularExpression` anchored to the full string.
    static func compileGlob(_ pattern: String) throws -> NSRegularExpression {
        var out = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                out.append(".*")
            case "?":
                out.append(".")
            case "[":
                // Pass through as-is until matching ']'.
                out.append("[")
                i = pattern.index(after: i)
                while i < pattern.endIndex, pattern[i] != "]" {
                    let inner = pattern[i]
                    if "\\^$".contains(inner) { out.append("\\") }
                    out.append(inner)
                    i = pattern.index(after: i)
                }
                if i < pattern.endIndex { out.append("]") }
            case "\\":
                // Escape next char literally.
                i = pattern.index(after: i)
                if i < pattern.endIndex {
                    out.append(NSRegularExpression.escapedPattern(for: String(pattern[i])))
                }
            default:
                out.append(NSRegularExpression.escapedPattern(for: String(c)))
            }
            if i < pattern.endIndex {
                i = pattern.index(after: i)
            }
        }
        out.append("$")
        return try NSRegularExpression(pattern: out, options: [])
    }
}

public enum KeyStoreError: Swift.Error, Equatable, CustomStringConvertible {
    case wrongType
    case noSuchKey
    /// Generic application-level error carrying a wire-formatted message.
    /// Used by string-store extensions for INCR overflow, type-coerce
    /// failures, invalid offsets, etc.
    case appError(String)

    public var description: String {
        switch self {
        case .wrongType: return "WRONGTYPE Operation against a key holding the wrong kind of value"
        case .noSuchKey: return "ERR no such key"
        case .appError(let m): return m
        }
    }
}
