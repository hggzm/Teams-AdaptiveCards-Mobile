import Csqlite3
import Foundation

/// Phase 9 — set-typed commands. Uses redka's `rset(kid, elem BLOB)`
/// table with a unique index on (kid, elem).
extension KeyStore {

    // MARK: - SADD / SREM

    @discardableResult
    public func sadd(key: String, members: [Data]) throws -> Int {
        try mutateSet(key: key) { conn, kid in
            var added = 0
            for m in members {
                let existed: [Int64] = try conn.run(
                    "SELECT 1 FROM rset WHERE kid = ? AND elem = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, m)
                    },
                    rowMap: { _ in 1 }
                )
                if existed.isEmpty {
                    try conn.run(
                        "INSERT INTO rset (kid, elem) VALUES (?, ?)",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, m)
                        },
                        rowMap: { _ in () }
                    )
                    added += 1
                }
            }
            return added
        }
    }

    public func srem(key: String, members: [Data]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                    try conn.exec("ROLLBACK"); return 0
                }
                var removed = 0
                for m in members {
                    try conn.run(
                        "DELETE FROM rset WHERE kid = ? AND elem = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, m)
                        },
                        rowMap: { _ in () }
                    )
                    removed += conn.changes()
                }
                try Self.dropSetIfEmpty(conn: conn, kid: kid)
                try conn.exec("COMMIT")
                return removed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - SISMEMBER / SMEMBERS / SCARD

    public func sismember(key: String, member: Data) throws -> Bool {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                return false
            }
            let rows: [Int64] = try conn.run(
                "SELECT 1 FROM rset WHERE kid = ? AND elem = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindBlob(stmt, 2, member)
                },
                rowMap: { _ in 1 }
            )
            return !rows.isEmpty
        }
    }

    public func smembers(key: String) throws -> [Data] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                return []
            }
            return try conn.run(
                "SELECT elem FROM rset WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
        }
    }

    public func scard(key: String) throws -> Int {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                return 0
            }
            let rows: [Int64] = try conn.run(
                "SELECT COUNT(*) FROM rset WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return Int(rows.first ?? 0)
        }
    }

    // MARK: - SPOP / SRANDMEMBER

    public func spop(key: String, count: Int = 1) throws -> [Data] {
        guard count > 0 else { return [] }
        return try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                    try conn.exec("ROLLBACK"); return []
                }
                let rows: [Data] = try conn.run(
                    "SELECT elem FROM rset WHERE kid = ? ORDER BY RANDOM() LIMIT ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindInt64(stmt, 2, Int64(count))
                    },
                    rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
                )
                for m in rows {
                    try conn.run(
                        "DELETE FROM rset WHERE kid = ? AND elem = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, m)
                        },
                        rowMap: { _ in () }
                    )
                }
                try Self.dropSetIfEmpty(conn: conn, kid: kid)
                try conn.exec("COMMIT")
                return rows
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// `SRANDMEMBER key [count]` — when count is negative Redis allows
    /// duplicates; swiftka v0 only implements the count>=0 distinct
    /// path, which is what the vast majority of clients use.
    public func srandmember(key: String, count: Int? = nil) throws -> [Data] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                return []
            }
            let lim = max(1, count ?? 1)
            return try conn.run(
                "SELECT elem FROM rset WHERE kid = ? ORDER BY RANDOM() LIMIT ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, Int64(lim))
                },
                rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
            )
        }
    }

    // MARK: - SDIFF / SDIFFSTORE / SINTER / SINTERSTORE / SUNION / SUNIONSTORE

    public func sdiff(keys: [String]) throws -> [Data] {
        try setCombine(keys: keys) { sets in
            guard let first = sets.first else { return [] }
            return first.subtracting(sets.dropFirst().reduce(Set<Data>()) { $0.union($1) })
                        .toArray()
        }
    }

    public func sinter(keys: [String]) throws -> [Data] {
        try setCombine(keys: keys) { sets in
            guard let first = sets.first else { return [] }
            return sets.dropFirst().reduce(first) { $0.intersection($1) }.toArray()
        }
    }

    public func sunion(keys: [String]) throws -> [Data] {
        try setCombine(keys: keys) { sets in
            sets.reduce(Set<Data>()) { $0.union($1) }.toArray()
        }
    }

    public func sdiffstore(dst: String, keys: [String]) throws -> Int {
        try storeResult(dst: dst, members: try sdiff(keys: keys))
    }

    public func sinterstore(dst: String, keys: [String]) throws -> Int {
        try storeResult(dst: dst, members: try sinter(keys: keys))
    }

    public func sunionstore(dst: String, keys: [String]) throws -> Int {
        try storeResult(dst: dst, members: try sunion(keys: keys))
    }

    // MARK: - SMOVE / SSCAN

    public func smove(src: String, dst: String, member: Data) throws -> Bool {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let srcKid = try Self.fetchKidForType(conn: conn, key: src, type: .set) else {
                    try conn.exec("ROLLBACK"); return false
                }
                let hits: [Int64] = try conn.run(
                    "SELECT 1 FROM rset WHERE kid = ? AND elem = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, srcKid)
                        SQLiteConnection.bindBlob(stmt, 2, member)
                    },
                    rowMap: { _ in 1 }
                )
                guard !hits.isEmpty else {
                    try conn.exec("ROLLBACK"); return false
                }
                try conn.run(
                    "DELETE FROM rset WHERE kid = ? AND elem = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, srcKid)
                        SQLiteConnection.bindBlob(stmt, 2, member)
                    },
                    rowMap: { _ in () }
                )
                try Self.dropSetIfEmpty(conn: conn, kid: srcKid)
                try Self.upsertKeyLocked(conn: conn, key: dst, type: .set)
                let dstKid = try Self.fetchKidLocked(conn: conn, key: dst)
                try conn.run(
                    "INSERT OR IGNORE INTO rset (kid, elem) VALUES (?, ?)",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, dstKid)
                        SQLiteConnection.bindBlob(stmt, 2, member)
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

    public func sscan(key: String, cursor: Int = 0, match: String? = nil, count: Int? = nil) throws -> (Int, [Data]) {
        let all = try smembers(key: key)
        if let pattern = match, !pattern.isEmpty {
            let regex = try KeyStore.compileGlob(pattern)
            let filtered = all.filter { d in
                guard let s = String(data: d, encoding: .utf8) else { return false }
                let ns = s as NSString
                return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
            }
            return (0, filtered)
        }
        _ = cursor; _ = count
        return (0, all)
    }

    // MARK: - Helpers

    private func mutateSet<T>(key: String, _ body: (SQLiteConnection, Int64) throws -> T) throws -> T {
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
                if let t = existing.first, t != RedkaType.set.rawValue {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .set)
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

    /// Loads the named sets into memory and combines them via `combine`.
    /// Missing keys are treated as empty sets; non-set types throw
    /// WRONGTYPE.
    private func setCombine(keys: [String], combine: (ArraySlice<Set<Data>>) -> [Data]) throws -> [Data] {
        try database.withLock { conn in
            var sets: [Set<Data>] = []
            for key in keys {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .set) else {
                    sets.append(Set<Data>())
                    continue
                }
                let elems: [Data] = try conn.run(
                    "SELECT elem FROM rset WHERE kid = ?",
                    bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                    rowMap: { stmt in SQLiteConnection.columnBlob(stmt, 0) }
                )
                sets.append(Set(elems))
            }
            return combine(sets[sets.startIndex..<sets.endIndex])
        }
    }

    /// Writes the given members into `dst` as a brand-new set,
    /// replacing whatever was there. Returns the resulting cardinality.
    private func storeResult(dst: String, members: [Data]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                try conn.run(
                    "DELETE FROM rkey WHERE key = ?",
                    bind: { stmt in SQLiteConnection.bindText(stmt, 1, dst) },
                    rowMap: { _ in () }
                )
                if members.isEmpty {
                    try conn.exec("COMMIT")
                    return 0
                }
                try Self.upsertKeyLocked(conn: conn, key: dst, type: .set)
                let kid = try Self.fetchKidLocked(conn: conn, key: dst)
                for m in members {
                    try conn.run(
                        "INSERT OR IGNORE INTO rset (kid, elem) VALUES (?, ?)",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, m)
                        },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return members.count
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    static func dropSetIfEmpty(conn: SQLiteConnection, kid: Int64) throws {
        let rows: [Int64] = try conn.run(
            "SELECT COUNT(*) FROM rset WHERE kid = ?",
            bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
            rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
        )
        if (rows.first ?? 0) == 0 {
            try conn.run(
                "DELETE FROM rkey WHERE id = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { _ in () }
            )
        }
    }
}

private extension Set where Element == Data {
    func toArray() -> [Data] { Array(self) }
}
