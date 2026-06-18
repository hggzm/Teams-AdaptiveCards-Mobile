import Csqlite3
import Foundation

/// Phase 8 — hash-typed commands. Uses redka's `rhash(kid, field TEXT,
/// value BLOB)` table with a unique index on (kid, field).
extension KeyStore {

    // MARK: - HSET / HSETNX / HMSET

    /// `HSET key field value [field value ...]` — sets one or more
    /// field/value pairs and returns the number of NEW fields created
    /// (matches Redis 4+ semantics).
    @discardableResult
    public func hset(key: String, pairs: [(String, Data)]) throws -> Int {
        try mutateHash(key: key) { conn, kid in
            var newFields = 0
            for (field, value) in pairs {
                let existed: [Int64] = try conn.run(
                    "SELECT 1 FROM rhash WHERE kid = ? AND field = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, field)
                    },
                    rowMap: { _ in 1 }
                )
                if existed.isEmpty { newFields += 1 }
                try conn.run(
                    """
                    INSERT INTO rhash (kid, field, value) VALUES (?, ?, ?)
                    ON CONFLICT(kid, field) DO UPDATE SET value = excluded.value
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, field)
                        SQLiteConnection.bindBlob(stmt, 3, value)
                    },
                    rowMap: { _ in () }
                )
            }
            return newFields
        }
    }

    /// `HSETNX key field value` — set only if field does not exist.
    /// Returns true if the field was set.
    public func hsetnx(key: String, field: String, value: Data) throws -> Bool {
        try mutateHash(key: key) { conn, kid in
            let existed: [Int64] = try conn.run(
                "SELECT 1 FROM rhash WHERE kid = ? AND field = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, field)
                },
                rowMap: { _ in 1 }
            )
            if !existed.isEmpty { return false }
            try conn.run(
                "INSERT INTO rhash (kid, field, value) VALUES (?, ?, ?)",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, field)
                    SQLiteConnection.bindBlob(stmt, 3, value)
                },
                rowMap: { _ in () }
            )
            return true
        }
    }

    // MARK: - HGET / HMGET / HGETALL / HKEYS / HVALS / HEXISTS / HLEN

    public func hget(key: String, field: String) throws -> Data? {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return nil
            }
            let rows: [Data] = try conn.run(
                "SELECT value FROM rhash WHERE kid = ? AND field = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, field)
                },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
            return rows.first
        }
    }

    public func hmget(key: String, fields: [String]) throws -> [Data?] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return Array(repeating: nil, count: fields.count)
            }
            return try fields.map { field in
                let rows: [Data] = try conn.run(
                    "SELECT value FROM rhash WHERE kid = ? AND field = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, field)
                    },
                    rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
                )
                return rows.first
            }
        }
    }

    public func hgetall(key: String) throws -> [(String, Data)] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return []
            }
            return try conn.run(
                "SELECT field, value FROM rhash WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    (SQLiteConnection.columnText(stmt, 0),
                     SQLiteConnection.columnBlob(stmt, 1))
                }
            )
        }
    }

    public func hkeys(key: String) throws -> [String] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return []
            }
            return try conn.run(
                "SELECT field FROM rhash WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnText(stmt, 0) }
            )
        }
    }

    public func hvals(key: String) throws -> [Data] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return []
            }
            return try conn.run(
                "SELECT value FROM rhash WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
        }
    }

    public func hexists(key: String, field: String) throws -> Bool {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return false
            }
            let rows: [Int64] = try conn.run(
                "SELECT 1 FROM rhash WHERE kid = ? AND field = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, field)
                },
                rowMap: { _ in 1 }
            )
            return !rows.isEmpty
        }
    }

    public func hlen(key: String) throws -> Int {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return 0
            }
            let rows: [Int64] = try conn.run(
                "SELECT COUNT(*) FROM rhash WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return Int(rows.first ?? 0)
        }
    }

    // MARK: - HDEL / HINCRBY / HSCAN

    public func hdel(key: String, fields: [String]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                    try conn.exec("ROLLBACK")
                    return 0
                }
                var removed = 0
                for field in fields {
                    try conn.run(
                        "DELETE FROM rhash WHERE kid = ? AND field = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindText(stmt, 2, field)
                        },
                        rowMap: { _ in () }
                    )
                    removed += conn.changes()
                }
                // Drop the rkey row if the hash is now empty.
                let remaining: [Int64] = try conn.run(
                    "SELECT COUNT(*) FROM rhash WHERE kid = ?",
                    bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                    rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
                )
                if (remaining.first ?? 0) == 0 {
                    try conn.run(
                        "DELETE FROM rkey WHERE id = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return removed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    public func hincrBy(key: String, field: String, delta: Int64) throws -> Int64 {
        try mutateHash(key: key) { conn, kid in
            let rows: [Data] = try conn.run(
                "SELECT value FROM rhash WHERE kid = ? AND field = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, field)
                },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
            let current: Int64
            if let v = rows.first {
                guard let s = String(data: v, encoding: .utf8),
                      let n = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                    throw KeyStoreError.notInteger
                }
                current = n
            } else {
                current = 0
            }
            let (next, overflow) = current.addingReportingOverflow(delta)
            if overflow { throw KeyStoreError.overflow }
            try conn.run(
                """
                INSERT INTO rhash (kid, field, value) VALUES (?, ?, ?)
                ON CONFLICT(kid, field) DO UPDATE SET value = excluded.value
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, field)
                    SQLiteConnection.bindBlob(stmt, 3, Data(String(next).utf8))
                },
                rowMap: { _ in () }
            )
            return next
        }
    }

    /// Simple HSCAN: returns the next cursor (always `0` because we
    /// don't paginate yet) and all (field, value) pairs. Real cursor
    /// pagination can land later — clients that just iterate one page
    /// are correct.
    public func hscan(key: String, cursor: Int = 0, match: String? = nil, count: Int? = nil) throws -> (Int, [(String, Data)]) {
        let all = try hgetall(key: key)
        let filtered: [(String, Data)]
        if let pattern = match, !pattern.isEmpty {
            let regex = try KeyStore.compileGlob(pattern)
            filtered = all.filter { pair in
                let s = pair.0
                let ns = s as NSString
                return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
            }
        } else {
            filtered = all
        }
        _ = cursor; _ = count   // single-page iteration
        return (0, filtered)
    }

    // MARK: - Helpers

    private func mutateHash<T>(key: String, _ body: (SQLiteConnection, Int64) throws -> T) throws -> T {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let existing: [Int32] = try conn.run(
                    "SELECT type FROM rkey WHERE key = ? AND (etime IS NULL OR etime > ?)",
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                    },
                    rowMap: { stmt in Int32(SQLiteConnection.columnInt64(stmt, 0)) }
                )
                if let t = existing.first, t != RedkaType.hash.rawValue {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .hash)
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                let result = try body(conn, kid)
                try conn.exec("COMMIT")
                return result
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }
}
