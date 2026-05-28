import Csqlite3
import Foundation

/// Phase 11 — TTL/expiry commands. `rkey.etime` is already populated
/// by `SETEX`/`PSETEX` and filtered on every read; this file exposes
/// the wire surface (`EXPIRE`/`PEXPIRE`/`EXPIREAT`/`PEXPIREAT`/
/// `TTL`/`PTTL`/`PERSIST`).
extension KeyStore {

    /// Set a TTL on `key`. Returns `true` if the key existed (and the
    /// TTL was applied), `false` if it was missing.
    public func expire(key: String, ttlMS: Int64) throws -> Bool {
        let target = Self.nowMSStatic() + ttlMS
        return try setExpiry(key: key, etime: target)
    }

    /// Set an absolute expiry time (milliseconds since epoch).
    public func expireAt(key: String, atMS: Int64) throws -> Bool {
        try setExpiry(key: key, etime: atMS)
    }

    /// Remove the expiry from `key`. Returns `true` if the key existed
    /// and had an expiry (now cleared).
    public func persist(key: String) throws -> Bool {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let rows: [Int64?] = try conn.run(
                    """
                    SELECT etime FROM rkey
                    WHERE key = ?
                      AND (etime IS NULL OR etime > ?)
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                    },
                    rowMap: { stmt -> Int64? in
                        SQLiteConnection.columnIsNull(stmt, 0)
                            ? nil
                            : SQLiteConnection.columnInt64(stmt, 0)
                    }
                )
                guard let existing = rows.first else {
                    try conn.exec("ROLLBACK")
                    return false
                }
                guard existing != nil else {
                    // Key exists but had no expiry — Redis PERSIST returns 0 in that case.
                    try conn.exec("ROLLBACK")
                    return false
                }
                try conn.run(
                    "UPDATE rkey SET etime = NULL, mtime = ?, version = version + 1 WHERE key = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, Self.nowMSStatic())
                        SQLiteConnection.bindText(stmt, 2, key)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return true
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Time-to-live in milliseconds. Returns:
    /// - `-2` if the key doesn't exist
    /// - `-1` if the key exists but has no associated expire
    /// - the remaining TTL in milliseconds otherwise
    public func pttl(key: String) throws -> Int64 {
        try database.withLock { conn in
            let now = Self.nowMSStatic()
            let rows: [Int64?] = try conn.run(
                """
                SELECT etime FROM rkey
                WHERE key = ?
                  AND (etime IS NULL OR etime > ?)
                """,
                bind: { stmt in
                    SQLiteConnection.bindText(stmt, 1, key)
                    SQLiteConnection.bindInt64(stmt, 2, now)
                },
                rowMap: { stmt -> Int64? in
                    SQLiteConnection.columnIsNull(stmt, 0)
                        ? nil
                        : SQLiteConnection.columnInt64(stmt, 0)
                }
            )
            guard let existing = rows.first else { return -2 }
            guard let etime = existing else { return -1 }
            return max(0, etime - now)
        }
    }

    /// TTL in **seconds** (rounded down). Same sentinels as ``pttl``.
    public func ttl(key: String) throws -> Int64 {
        let ms = try pttl(key: key)
        if ms < 0 { return ms }
        return ms / 1000
    }

    // MARK: - Helpers

    /// Atomically applies an absolute expiry. Returns `false` if the
    /// key is missing or already expired.
    private func setExpiry(key: String, etime: Int64) throws -> Bool {
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
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                    },
                    rowMap: { _ in 1 }
                )
                guard !exists.isEmpty else {
                    try conn.exec("ROLLBACK")
                    return false
                }
                try conn.run(
                    "UPDATE rkey SET etime = ?, mtime = ?, version = version + 1 WHERE key = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, etime)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                        SQLiteConnection.bindText(stmt, 3, key)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return true
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }
}
