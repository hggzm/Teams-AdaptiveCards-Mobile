import Csqlite3
import Foundation

/// Phase 7 — list-typed commands. Uses redka's `rlist(kid, pos REAL,
/// elem BLOB)` table. The `pos` column is a float so we can insert
/// between any two elements without renumbering (LINSERT).
extension KeyStore {

    // MARK: - LPUSH / RPUSH

    /// `LPUSH key value [value ...]` — prepends one or more elements
    /// (each new value becomes the new head, matching Redis order).
    /// Returns the new list length.
    @discardableResult
    public func lpush(key: String, values: [Data]) throws -> Int {
        try mutateList(key: key) { conn, kid in
            for value in values {
                let minPos = try Self.minListPos(conn: conn, kid: kid)
                let next = (minPos ?? 0.0) - 1.0
                try Self.insertListElem(conn: conn, kid: kid, pos: next, elem: value)
            }
            return try Self.countList(conn: conn, kid: kid)
        }
    }

    /// `RPUSH key value [value ...]` — appends one or more elements.
    @discardableResult
    public func rpush(key: String, values: [Data]) throws -> Int {
        try mutateList(key: key) { conn, kid in
            for value in values {
                let maxPos = try Self.maxListPos(conn: conn, kid: kid)
                let next = (maxPos ?? 0.0) + 1.0
                try Self.insertListElem(conn: conn, kid: kid, pos: next, elem: value)
            }
            return try Self.countList(conn: conn, kid: kid)
        }
    }

    // MARK: - LPOP / RPOP

    public func lpop(key: String, count: Int = 1) throws -> [Data] {
        try popList(key: key, count: count, ascending: true)
    }

    public func rpop(key: String, count: Int = 1) throws -> [Data] {
        try popList(key: key, count: count, ascending: false)
    }

    private func popList(key: String, count: Int, ascending: Bool) throws -> [Data] {
        guard count > 0 else { return [] }
        return try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                    try conn.exec("ROLLBACK")
                    return []
                }
                let order = ascending ? "ASC" : "DESC"
                let rows: [(Double, Data)] = try conn.run(
                    """
                    SELECT pos, elem FROM rlist
                    WHERE kid = ?
                    ORDER BY pos \(order)
                    LIMIT ?
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindInt64(stmt, 2, Int64(count))
                    },
                    rowMap: { stmt in
                        (sqlite3_column_double(stmt, 0),
                         SQLiteConnection.columnBlob(stmt, 1))
                    }
                )
                for (pos, _) in rows {
                    try conn.run(
                        "DELETE FROM rlist WHERE kid = ? AND pos = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            sqlite3_bind_double(stmt, 2, pos)
                        },
                        rowMap: { _ in () }
                    )
                }
                let remaining = try Self.countList(conn: conn, kid: kid)
                if remaining == 0 {
                    try conn.run(
                        "DELETE FROM rkey WHERE id = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return rows.map(\.1)
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - LLEN

    public func llen(key: String) throws -> Int {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                return 0
            }
            return try Self.countList(conn: conn, kid: kid)
        }
    }

    // MARK: - LRANGE

    /// `LRANGE key start stop` — inclusive, negative indices count
    /// from the end.
    public func lrange(key: String, start: Int, stop: Int) throws -> [Data] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                return []
            }
            let n = try Self.countList(conn: conn, kid: kid)
            let (lo, hi) = Self.normaliseRange(start: start, stop: stop, count: n)
            if lo > hi { return [] }
            let limit = hi - lo + 1
            return try conn.run(
                """
                SELECT elem FROM rlist
                WHERE kid = ?
                ORDER BY pos ASC
                LIMIT ? OFFSET ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, Int64(limit))
                    SQLiteConnection.bindInt64(stmt, 3, Int64(lo))
                },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
        }
    }

    // MARK: - LINDEX

    public func lindex(key: String, index: Int) throws -> Data? {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                return nil
            }
            let n = try Self.countList(conn: conn, kid: kid)
            var i = index
            if i < 0 { i += n }
            if i < 0 || i >= n { return nil }
            let rows: [Data] = try conn.run(
                """
                SELECT elem FROM rlist
                WHERE kid = ?
                ORDER BY pos ASC
                LIMIT 1 OFFSET ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, Int64(i))
                },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
            return rows.first
        }
    }

    // MARK: - LSET

    public func lset(key: String, index: Int, value: Data) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.noSuchKey
                }
                let n = try Self.countList(conn: conn, kid: kid)
                var i = index
                if i < 0 { i += n }
                if i < 0 || i >= n {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("ERR index out of range")
                }
                let posRows: [Double] = try conn.run(
                    "SELECT pos FROM rlist WHERE kid = ? ORDER BY pos ASC LIMIT 1 OFFSET ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindInt64(stmt, 2, Int64(i))
                    },
                    rowMap: { stmt in sqlite3_column_double(stmt, 0) }
                )
                guard let pos = posRows.first else {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("ERR index out of range")
                }
                try conn.run(
                    "UPDATE rlist SET elem = ? WHERE kid = ? AND pos = ?",
                    bind: { stmt in
                        SQLiteConnection.bindBlob(stmt, 1, value)
                        SQLiteConnection.bindInt64(stmt, 2, kid)
                        sqlite3_bind_double(stmt, 3, pos)
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

    // MARK: - LREM

    /// `LREM key count element` — removes occurrences. count>0: from
    /// head, count<0: from tail, count==0: all.
    public func lrem(key: String, count: Int, element: Data) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                    try conn.exec("ROLLBACK")
                    return 0
                }
                let order = count >= 0 ? "ASC" : "DESC"
                let limitSQL: String
                if count == 0 { limitSQL = "" }
                else          { limitSQL = "LIMIT \(abs(count))" }
                let posRows: [Double] = try conn.run(
                    """
                    SELECT pos FROM rlist
                    WHERE kid = ? AND elem = ?
                    ORDER BY pos \(order)
                    \(limitSQL)
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, element)
                    },
                    rowMap: { stmt in sqlite3_column_double(stmt, 0) }
                )
                for pos in posRows {
                    try conn.run(
                        "DELETE FROM rlist WHERE kid = ? AND pos = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            sqlite3_bind_double(stmt, 2, pos)
                        },
                        rowMap: { _ in () }
                    )
                }
                let remaining = try Self.countList(conn: conn, kid: kid)
                if remaining == 0 {
                    try conn.run(
                        "DELETE FROM rkey WHERE id = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return posRows.count
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - LINSERT

    public enum LInsertWhere: String, Sendable { case before = "BEFORE", after = "AFTER" }

    /// `LINSERT key BEFORE|AFTER pivot value` — returns new list length,
    /// or `-1` if pivot not found, `0` if key missing.
    public func linsert(key: String,
                        position: LInsertWhere,
                        pivot: Data,
                        value: Data) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                    try conn.exec("ROLLBACK")
                    return 0
                }
                // Find pivot's pos (first occurrence from head).
                let pivots: [Double] = try conn.run(
                    "SELECT pos FROM rlist WHERE kid = ? AND elem = ? ORDER BY pos ASC LIMIT 1",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, pivot)
                    },
                    rowMap: { stmt in sqlite3_column_double(stmt, 0) }
                )
                guard let pivotPos = pivots.first else {
                    try conn.exec("ROLLBACK")
                    return -1
                }
                // Find neighbor pos in the requested direction.
                let neighbor: [Double]
                switch position {
                case .before:
                    neighbor = try conn.run(
                        "SELECT pos FROM rlist WHERE kid = ? AND pos < ? ORDER BY pos DESC LIMIT 1",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            sqlite3_bind_double(stmt, 2, pivotPos)
                        },
                        rowMap: { stmt in sqlite3_column_double(stmt, 0) }
                    )
                case .after:
                    neighbor = try conn.run(
                        "SELECT pos FROM rlist WHERE kid = ? AND pos > ? ORDER BY pos ASC LIMIT 1",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            sqlite3_bind_double(stmt, 2, pivotPos)
                        },
                        rowMap: { stmt in sqlite3_column_double(stmt, 0) }
                    )
                }
                let newPos: Double
                if let n = neighbor.first {
                    newPos = (pivotPos + n) / 2.0
                } else {
                    newPos = position == .before ? pivotPos - 1.0 : pivotPos + 1.0
                }
                try Self.insertListElem(conn: conn, kid: kid, pos: newPos, elem: value)
                let total = try Self.countList(conn: conn, kid: kid)
                try conn.exec("COMMIT")
                return total
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - LTRIM

    public func ltrim(key: String, start: Int, stop: Int) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .list) else {
                    try conn.exec("ROLLBACK")
                    return
                }
                let n = try Self.countList(conn: conn, kid: kid)
                let (lo, hi) = Self.normaliseRange(start: start, stop: stop, count: n)
                if lo > hi {
                    // Empty result -> drop the whole list.
                    try conn.run(
                        "DELETE FROM rkey WHERE id = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { _ in () }
                    )
                    try conn.exec("COMMIT")
                    return
                }
                // Pick the positions that survive, then delete the rest.
                let keepRows: [Double] = try conn.run(
                    "SELECT pos FROM rlist WHERE kid = ? ORDER BY pos ASC LIMIT ? OFFSET ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindInt64(stmt, 2, Int64(hi - lo + 1))
                        SQLiteConnection.bindInt64(stmt, 3, Int64(lo))
                    },
                    rowMap: { stmt in sqlite3_column_double(stmt, 0) }
                )
                if keepRows.isEmpty {
                    try conn.run(
                        "DELETE FROM rkey WHERE id = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { _ in () }
                    )
                } else {
                    let minKeep = keepRows.first!
                    let maxKeep = keepRows.last!
                    try conn.run(
                        "DELETE FROM rlist WHERE kid = ? AND (pos < ? OR pos > ?)",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            sqlite3_bind_double(stmt, 2, minKeep)
                            sqlite3_bind_double(stmt, 3, maxKeep)
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

    // MARK: - RPOPLPUSH

    /// Atomically pops the tail of `src` and pushes it to the head of
    /// `dst`. Returns the moved element, or `nil` if `src` is empty.
    public func rpopLpush(src: String, dst: String) throws -> Data? {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let srcKid = try Self.fetchKidForType(conn: conn, key: src, type: .list) else {
                    try conn.exec("ROLLBACK")
                    return nil
                }
                let rows: [(Double, Data)] = try conn.run(
                    "SELECT pos, elem FROM rlist WHERE kid = ? ORDER BY pos DESC LIMIT 1",
                    bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, srcKid) },
                    rowMap: { stmt in
                        (sqlite3_column_double(stmt, 0),
                         SQLiteConnection.columnBlob(stmt, 1))
                    }
                )
                guard let (pos, elem) = rows.first else {
                    try conn.exec("ROLLBACK")
                    return nil
                }
                try conn.run(
                    "DELETE FROM rlist WHERE kid = ? AND pos = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, srcKid)
                        sqlite3_bind_double(stmt, 2, pos)
                    },
                    rowMap: { _ in () }
                )
                // Drop src key if now empty.
                if try Self.countList(conn: conn, kid: srcKid) == 0 {
                    try conn.run(
                        "DELETE FROM rkey WHERE id = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, srcKid) },
                        rowMap: { _ in () }
                    )
                }
                // Ensure dst rkey exists as a list.
                try Self.upsertKeyLocked(conn: conn, key: dst, type: .list)
                let dstKid = try Self.fetchKidLocked(conn: conn, key: dst)
                let minPos = try Self.minListPos(conn: conn, kid: dstKid)
                let newPos = (minPos ?? 0.0) - 1.0
                try Self.insertListElem(conn: conn, kid: dstKid, pos: newPos, elem: elem)
                try conn.exec("COMMIT")
                return elem
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - BLPOP (timeout-only stub — non-blocking in v0)

    /// `BLPOP key [key ...] timeout` — returns the first non-empty
    /// list's head element (with its key) immediately without blocking.
    /// Real blocking semantics arrive in a later phase; until then this
    /// behaves exactly like LPOP on the first key that has anything.
    public func blpop(keys: [String]) throws -> (String, Data)? {
        for key in keys {
            let popped = try lpop(key: key, count: 1)
            if let v = popped.first { return (key, v) }
        }
        return nil
    }

    // MARK: - Helpers

    /// Pattern for list mutators: opens a transaction, ensures the rkey
    /// row exists with type=list, runs `body`, commits or rolls back.
    private func mutateList<T>(key: String, _ body: (SQLiteConnection, Int64) throws -> T) throws -> T {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                // Type guard: if the key exists with a non-list type,
                // refuse (WRONGTYPE).
                let existing: [Int32] = try conn.run(
                    "SELECT type FROM rkey WHERE key = ? AND (etime IS NULL OR etime > ?)",
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                    },
                    rowMap: { stmt in Int32(SQLiteConnection.columnInt64(stmt, 0)) }
                )
                if let t = existing.first, t != RedkaType.list.rawValue {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .list)
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

    /// Looks up the rkey id for a key with the requested type, gating
    /// out wrong-type and missing/expired entries. Returns `nil` if the
    /// key is missing; throws on WRONGTYPE.
    static func fetchKidForType(conn: SQLiteConnection,
                                key: String,
                                type: RedkaType) throws -> Int64? {
        let rows: [(Int64, Int32)] = try conn.run(
            """
            SELECT id, type FROM rkey
            WHERE key = ?
              AND (etime IS NULL OR etime > ?)
            """,
            bind: { stmt in
                SQLiteConnection.bindText(stmt, 1, key)
                SQLiteConnection.bindInt64(stmt, 2, nowMSStatic())
            },
            rowMap: { stmt in
                (SQLiteConnection.columnInt64(stmt, 0),
                 Int32(SQLiteConnection.columnInt64(stmt, 1)))
            }
        )
        guard let (id, t) = rows.first else { return nil }
        if t != type.rawValue { throw KeyStoreError.wrongType }
        return id
    }

    static func minListPos(conn: SQLiteConnection, kid: Int64) throws -> Double? {
        let rows: [Double] = try conn.run(
            "SELECT MIN(pos) FROM rlist WHERE kid = ?",
            bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
            rowMap: { stmt in
                SQLiteConnection.columnIsNull(stmt, 0) ? Double.nan : sqlite3_column_double(stmt, 0)
            }
        )
        guard let v = rows.first, !v.isNaN else { return nil }
        return v
    }

    static func maxListPos(conn: SQLiteConnection, kid: Int64) throws -> Double? {
        let rows: [Double] = try conn.run(
            "SELECT MAX(pos) FROM rlist WHERE kid = ?",
            bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
            rowMap: { stmt in
                SQLiteConnection.columnIsNull(stmt, 0) ? Double.nan : sqlite3_column_double(stmt, 0)
            }
        )
        guard let v = rows.first, !v.isNaN else { return nil }
        return v
    }

    static func countList(conn: SQLiteConnection, kid: Int64) throws -> Int {
        let rows: [Int64] = try conn.run(
            "SELECT COUNT(*) FROM rlist WHERE kid = ?",
            bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
            rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
        )
        return Int(rows.first ?? 0)
    }

    static func insertListElem(conn: SQLiteConnection,
                               kid: Int64, pos: Double, elem: Data) throws {
        try conn.run(
            "INSERT INTO rlist (kid, pos, elem) VALUES (?, ?, ?)",
            bind: { stmt in
                SQLiteConnection.bindInt64(stmt, 1, kid)
                sqlite3_bind_double(stmt, 2, pos)
                SQLiteConnection.bindBlob(stmt, 3, elem)
            },
            rowMap: { _ in () }
        )
    }

    /// Normalises a Redis-style inclusive range against a known length.
    /// Returns `(lo, hi)` both clamped to `[0, count-1]`. `lo > hi`
    /// indicates an empty slice.
    static func normaliseRange(start: Int, stop: Int, count: Int) -> (Int, Int) {
        if count == 0 { return (1, 0) }
        var lo = start, hi = stop
        if lo < 0 { lo += count }
        if hi < 0 { hi += count }
        lo = max(0, lo)
        hi = min(count - 1, hi)
        return (lo, hi)
    }
}
