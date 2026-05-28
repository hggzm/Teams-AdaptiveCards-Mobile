import Csqlite3
import Foundation

/// Phase 16 — read-only helper that snapshots `rkey.version` for a set
/// of keys, used by WATCH to detect concurrent mutations between WATCH
/// and EXEC.
extension KeyStore {
    /// Sentinel returned for keys that did not exist at snapshot time.
    /// rkey.version is always >= 1 for live rows, so -1 can't collide.
    public static let missingKeyVersion: Int64 = -1

    /// Returns `(key → current version)` for every requested key. A
    /// missing/expired key maps to ``missingKeyVersion`` (-1) so EXEC
    /// can detect both "key was modified" and "key was created".
    public func snapshotVersions(of keys: [String]) throws -> [String: Int64] {
        try database.withLock { conn in
            var out: [String: Int64] = [:]
            for key in keys {
                let rows: [Int64] = try conn.run(
                    """
                    SELECT version FROM rkey
                    WHERE key = ?
                      AND (etime IS NULL OR etime > ?)
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                    },
                    rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
                )
                out[key] = rows.first ?? Self.missingKeyVersion
            }
            return out
        }
    }
}
