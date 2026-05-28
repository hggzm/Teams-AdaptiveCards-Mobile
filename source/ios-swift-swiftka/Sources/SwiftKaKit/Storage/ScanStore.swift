import Csqlite3
import Foundation

/// Phase 15 — `SCAN cursor [MATCH pattern] [COUNT n] [TYPE t]` plus
/// real cursor pagination for HSCAN / SSCAN / ZSCAN.
///
/// The cursor for `SCAN` is the largest `rkey.id` already returned.
/// Each call selects the next batch via `WHERE id > cursor ORDER BY id
/// LIMIT count`. When the underlying SELECT returns fewer rows than
/// `count`, the iteration is complete and the next-cursor is `0`. This
/// is a perfectly stable iteration as long as new keys are appended at
/// higher rowids than what's been seen — which is always true under
/// SQLite's INTEGER PRIMARY KEY semantics.
extension KeyStore {

    /// Default page size when callers don't supply `COUNT`.
    static let defaultScanCount = 50

    public func scan(cursor: Int64,
                     match: String? = nil,
                     count: Int? = nil,
                     type: RedkaType? = nil) throws -> (Int64, [String]) {
        let limit = count ?? Self.defaultScanCount
        return try database.withLock { conn in
            // We over-fetch by `2*limit` when filtering is active to
            // reduce the chance of returning an empty page despite
            // more matches existing further down — this keeps the
            // common case (no pattern, no type filter) one round-trip.
            let probe = (match == nil && type == nil) ? limit : limit * 2
            var rows: [(Int64, String, Int32)]
            if let t = type {
                rows = try conn.run(
                    """
                    SELECT id, key, type FROM rkey
                    WHERE id > ?
                      AND type = ?
                      AND (etime IS NULL OR etime > ?)
                    ORDER BY id
                    LIMIT ?
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, cursor)
                        SQLiteConnection.bindInt64(stmt, 2, Int64(t.rawValue))
                        SQLiteConnection.bindInt64(stmt, 3, Self.nowMSStatic())
                        SQLiteConnection.bindInt64(stmt, 4, Int64(probe))
                    },
                    rowMap: { stmt in
                        (SQLiteConnection.columnInt64(stmt, 0),
                         SQLiteConnection.columnText(stmt, 1),
                         Int32(SQLiteConnection.columnInt64(stmt, 2)))
                    }
                )
                _ = type
            } else {
                rows = try conn.run(
                    """
                    SELECT id, key, type FROM rkey
                    WHERE id > ?
                      AND (etime IS NULL OR etime > ?)
                    ORDER BY id
                    LIMIT ?
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, cursor)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                        SQLiteConnection.bindInt64(stmt, 3, Int64(probe))
                    },
                    rowMap: { stmt in
                        (SQLiteConnection.columnInt64(stmt, 0),
                         SQLiteConnection.columnText(stmt, 1),
                         Int32(SQLiteConnection.columnInt64(stmt, 2)))
                    }
                )
            }

            // Apply MATCH filter in memory (SQL LIKE can't model Redis
            // globs cleanly).
            let names: [String]
            if let pattern = match, !pattern.isEmpty {
                let regex = try KeyStore.compileGlob(pattern)
                names = rows.compactMap { (_, k, _) in
                    let ns = k as NSString
                    return regex.firstMatch(in: k, range: NSRange(location: 0, length: ns.length)) != nil ? k : nil
                }
            } else {
                names = rows.map(\.1)
            }

            // Cursor logic: if the SELECT returned fewer than the
            // probe size, we've exhausted the table → next cursor 0.
            // Otherwise carry the largest id forward.
            let nextCursor: Int64
            if rows.count < probe {
                nextCursor = 0
            } else if let last = rows.last {
                nextCursor = last.0
            } else {
                nextCursor = 0
            }
            return (nextCursor, names)
        }
    }
}

// MARK: - Sub-table SCAN re-implementations

extension KeyStore {

    /// Real HSCAN: cursor is the rowid offset (1-based) inside the
    /// hash's (kid, field) page. Pages of `count` matching entries are
    /// returned; next cursor is 0 when no more rows remain.
    public func hscan2(key: String,
                       cursor: Int64,
                       match: String? = nil,
                       count: Int? = nil) throws -> (Int64, [(String, Data)]) {
        let limit = count ?? Self.defaultScanCount
        return try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .hash) else {
                return (0, [])
            }
            let probe = (match == nil) ? limit : limit * 2
            // SQLite's `rowid` is a stable, monotonic per-row id even
            // on `STRICT` tables (rowid is allocated unless we declare
            // `WITHOUT ROWID`, which redka's schema doesn't).
            let rows: [(Int64, String, Data)] = try conn.run(
                """
                SELECT rowid, field, value FROM rhash
                WHERE kid = ? AND rowid > ?
                ORDER BY rowid
                LIMIT ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, cursor)
                    SQLiteConnection.bindInt64(stmt, 3, Int64(probe))
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnText(stmt, 1),
                     SQLiteConnection.columnBlob(stmt, 2))
                }
            )
            let pairs: [(String, Data)]
            if let pattern = match, !pattern.isEmpty {
                let regex = try KeyStore.compileGlob(pattern)
                pairs = rows.compactMap { (_, f, v) in
                    let ns = f as NSString
                    return regex.firstMatch(in: f, range: NSRange(location: 0, length: ns.length)) != nil
                        ? (f, v) : nil
                }
            } else {
                pairs = rows.map { ($0.1, $0.2) }
            }
            let nextCursor: Int64 = rows.count < probe ? 0 : (rows.last?.0 ?? 0)
            return (nextCursor, pairs)
        }
    }

    public func sscan2(key: String,
                       cursor: Int64,
                       match: String? = nil,
                       count: Int? = nil) throws -> (Int64, [Data]) {
        let limit = count ?? Self.defaultScanCount
        return try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                return (0, [])
            }
            let probe = (match == nil) ? limit : limit * 2
            let rows: [(Int64, Data)] = try conn.run(
                """
                SELECT rowid, elem FROM rset
                WHERE kid = ? AND rowid > ?
                ORDER BY rowid
                LIMIT ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, cursor)
                    SQLiteConnection.bindInt64(stmt, 3, Int64(probe))
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnBlob(stmt, 1))
                }
            )
            let elems: [Data]
            if let pattern = match, !pattern.isEmpty {
                let regex = try KeyStore.compileGlob(pattern)
                elems = rows.compactMap { (_, d) in
                    guard let s = String(data: d, encoding: .utf8) else { return nil }
                    let ns = s as NSString
                    return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil ? d : nil
                }
            } else {
                elems = rows.map(\.1)
            }
            let nextCursor: Int64 = rows.count < probe ? 0 : (rows.last?.0 ?? 0)
            return (nextCursor, elems)
        }
    }

    public func zscan2(key: String,
                       cursor: Int64,
                       match: String? = nil,
                       count: Int? = nil) throws -> (Int64, [(Data, Double)]) {
        let limit = count ?? Self.defaultScanCount
        return try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return (0, [])
            }
            let probe = (match == nil) ? limit : limit * 2
            let rows: [(Int64, Data, Double)] = try conn.run(
                """
                SELECT rowid, elem, score FROM rzset
                WHERE kid = ? AND rowid > ?
                ORDER BY rowid
                LIMIT ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, cursor)
                    SQLiteConnection.bindInt64(stmt, 3, Int64(probe))
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnBlob(stmt, 1),
                     sqlite3_column_double(stmt, 2))
                }
            )
            let pairs: [(Data, Double)]
            if let pattern = match, !pattern.isEmpty {
                let regex = try KeyStore.compileGlob(pattern)
                pairs = rows.compactMap { (_, d, s) in
                    guard let str = String(data: d, encoding: .utf8) else { return nil }
                    let ns = str as NSString
                    return regex.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)) != nil
                        ? (d, s) : nil
                }
            } else {
                pairs = rows.map { ($0.1, $0.2) }
            }
            let nextCursor: Int64 = rows.count < probe ? 0 : (rows.last?.0 ?? 0)
            return (nextCursor, pairs)
        }
    }
}
