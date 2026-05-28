import Csqlite3
import Foundation

/// Phase 18 helpers — minimal storage support for introspection
/// commands (`OBJECT`, `DBSIZE`, `FLUSHDB`, etc).
extension KeyStore {
    /// Total live (non-expired) keys.
    public func dbSize() throws -> Int {
        try database.withLock { conn in
            let rows: [Int64] = try conn.run(
                "SELECT COUNT(*) FROM rkey WHERE etime IS NULL OR etime > ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, Self.nowMSStatic()) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return Int(rows.first ?? 0)
        }
    }

    /// Wipes every key from the database (FLUSHDB / FLUSHALL).
    public func flushdb() throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                // The rkey row's ON DELETE CASCADE drops every per-type
                // sub-table entry too.
                try conn.exec("DELETE FROM rkey")
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Returns the `(version, mtime)` pair for a key, or `nil` if it
    /// doesn't exist. Used by OBJECT/DEBUG to surface real metadata.
    public func objectMeta(key: String) throws -> (version: Int64, mtimeMS: Int64, type: RedkaType)? {
        try database.withLock { conn in
            let rows: [(Int64, Int64, Int32)] = try conn.run(
                """
                SELECT version, mtime, type FROM rkey
                WHERE key = ?
                  AND (etime IS NULL OR etime > ?)
                """,
                bind: { stmt in
                    SQLiteConnection.bindText(stmt, 1, key)
                    SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnInt64(stmt, 1),
                     Int32(SQLiteConnection.columnInt64(stmt, 2)))
                }
            )
            guard let (v, m, t) = rows.first,
                  let kind = RedkaType(rawValue: t) else { return nil }
            return (v, m, kind)
        }
    }
}
