import Csqlite3
import Foundation

/// Phase 10 — sorted-set ("zset") commands. Uses redka's
/// `rzset(kid, elem BLOB, score REAL)` table with a unique index on
/// (kid, elem) and a secondary index on (kid, score, elem) for
/// score-ordered scans.
extension KeyStore {

    public struct ZSetMember: Equatable, Sendable {
        public var elem: Data
        public var score: Double
        public init(elem: Data, score: Double) {
            self.elem = elem
            self.score = score
        }
    }

    // MARK: - ZADD

    /// Adds one or more (score, elem) pairs. Returns the number of
    /// NEW elements added (existing elements have their score updated
    /// but don't count toward the return value, matching Redis default
    /// semantics).
    @discardableResult
    public func zadd(key: String, members: [(Double, Data)]) throws -> Int {
        try mutateZSet(key: key) { conn, kid in
            var added = 0
            for (score, elem) in members {
                let existed: [Int64] = try conn.run(
                    "SELECT 1 FROM rzset WHERE kid = ? AND elem = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, elem)
                    },
                    rowMap: { _ in 1 }
                )
                if existed.isEmpty {
                    added += 1
                    try conn.run(
                        "INSERT INTO rzset (kid, elem, score) VALUES (?, ?, ?)",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, elem)
                            sqlite3_bind_double(stmt, 3, score)
                        },
                        rowMap: { _ in () }
                    )
                } else {
                    try conn.run(
                        "UPDATE rzset SET score = ? WHERE kid = ? AND elem = ?",
                        bind: { stmt in
                            sqlite3_bind_double(stmt, 1, score)
                            SQLiteConnection.bindInt64(stmt, 2, kid)
                            SQLiteConnection.bindBlob(stmt, 3, elem)
                        },
                        rowMap: { _ in () }
                    )
                }
            }
            return added
        }
    }

    // MARK: - ZSCORE / ZRANK / ZREVRANK / ZCARD / ZCOUNT

    public func zscore(key: String, member: Data) throws -> Double? {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return nil
            }
            let rows: [Double] = try conn.run(
                "SELECT score FROM rzset WHERE kid = ? AND elem = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindBlob(stmt, 2, member)
                },
                rowMap: { stmt in sqlite3_column_double(stmt, 0) }
            )
            return rows.first
        }
    }

    public func zrank(key: String, member: Data, reverse: Bool = false) throws -> Int? {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return nil
            }
            let order = reverse ? "DESC" : "ASC"
            let rows: [(Int64, Data)] = try conn.run(
                "SELECT score, elem FROM rzset WHERE kid = ? ORDER BY score \(order), elem \(order)",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    (Int64(0), SQLiteConnection.columnBlob(stmt, 1))
                }
            )
            for (i, (_, elem)) in rows.enumerated() {
                if elem == member { return i }
            }
            return nil
        }
    }

    public func zcard(key: String) throws -> Int {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return 0
            }
            let rows: [Int64] = try conn.run(
                "SELECT COUNT(*) FROM rzset WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return Int(rows.first ?? 0)
        }
    }

    public func zcount(key: String, min: Double, max: Double) throws -> Int {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return 0
            }
            let rows: [Int64] = try conn.run(
                "SELECT COUNT(*) FROM rzset WHERE kid = ? AND score >= ? AND score <= ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    sqlite3_bind_double(stmt, 2, min)
                    sqlite3_bind_double(stmt, 3, max)
                },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return Int(rows.first ?? 0)
        }
    }

    // MARK: - ZRANGE / ZRANGEBYSCORE

    /// `ZRANGE key start stop [WITHSCORES]` — index-based, ascending
    /// by (score, elem). Negative indices count from the end.
    public func zrange(key: String, start: Int, stop: Int, reverse: Bool = false) throws -> [ZSetMember] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return []
            }
            let n = try Self.countZSet(conn: conn, kid: kid)
            let (lo, hi) = Self.normaliseRange(start: start, stop: stop, count: n)
            if lo > hi { return [] }
            let order = reverse ? "DESC" : "ASC"
            return try conn.run(
                """
                SELECT elem, score FROM rzset
                WHERE kid = ?
                ORDER BY score \(order), elem \(order)
                LIMIT ? OFFSET ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, Int64(hi - lo + 1))
                    SQLiteConnection.bindInt64(stmt, 3, Int64(lo))
                },
                rowMap: { stmt in
                    ZSetMember(elem: SQLiteConnection.columnBlob(stmt, 0),
                               score: sqlite3_column_double(stmt, 1))
                }
            )
        }
    }

    public func zrangeByScore(key: String, min: Double, max: Double,
                              offset: Int = 0, count: Int? = nil,
                              reverse: Bool = false) throws -> [ZSetMember] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return []
            }
            let order = reverse ? "DESC" : "ASC"
            let limit = count ?? -1
            return try conn.run(
                """
                SELECT elem, score FROM rzset
                WHERE kid = ? AND score >= ? AND score <= ?
                ORDER BY score \(order), elem \(order)
                LIMIT ? OFFSET ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    sqlite3_bind_double(stmt, 2, min)
                    sqlite3_bind_double(stmt, 3, max)
                    SQLiteConnection.bindInt64(stmt, 4, Int64(limit))
                    SQLiteConnection.bindInt64(stmt, 5, Int64(offset))
                },
                rowMap: { stmt in
                    ZSetMember(elem: SQLiteConnection.columnBlob(stmt, 0),
                               score: sqlite3_column_double(stmt, 1))
                }
            )
        }
    }

    // MARK: - ZINCRBY / ZREM

    /// Adds `delta` to the member's score (creating the member with
    /// score=delta if missing). Returns the new score.
    public func zincrBy(key: String, delta: Double, member: Data) throws -> Double {
        try mutateZSet(key: key) { conn, kid in
            let existing: [Double] = try conn.run(
                "SELECT score FROM rzset WHERE kid = ? AND elem = ?",
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindBlob(stmt, 2, member)
                },
                rowMap: { stmt in sqlite3_column_double(stmt, 0) }
            )
            let next = (existing.first ?? 0) + delta
            if existing.isEmpty {
                try conn.run(
                    "INSERT INTO rzset (kid, elem, score) VALUES (?, ?, ?)",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, member)
                        sqlite3_bind_double(stmt, 3, next)
                    },
                    rowMap: { _ in () }
                )
            } else {
                try conn.run(
                    "UPDATE rzset SET score = ? WHERE kid = ? AND elem = ?",
                    bind: { stmt in
                        sqlite3_bind_double(stmt, 1, next)
                        SQLiteConnection.bindInt64(stmt, 2, kid)
                        SQLiteConnection.bindBlob(stmt, 3, member)
                    },
                    rowMap: { _ in () }
                )
            }
            return next
        }
    }

    public func zrem(key: String, members: [Data]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                    try conn.exec("ROLLBACK"); return 0
                }
                var removed = 0
                for m in members {
                    try conn.run(
                        "DELETE FROM rzset WHERE kid = ? AND elem = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, m)
                        },
                        rowMap: { _ in () }
                    )
                    removed += conn.changes()
                }
                try Self.dropZSetIfEmpty(conn: conn, kid: kid)
                try conn.exec("COMMIT")
                return removed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - ZUNIONSTORE / ZINTERSTORE

    public enum ZSetAggregate: String, Sendable { case sum = "SUM", min = "MIN", max = "MAX" }

    /// `ZUNIONSTORE dst numkeys key [key ...] [AGGREGATE SUM|MIN|MAX]`
    public func zunionstore(dst: String, keys: [String], aggregate: ZSetAggregate = .sum) throws -> Int {
        try zComboStore(dst: dst, keys: keys, aggregate: aggregate, intersect: false)
    }

    public func zinterstore(dst: String, keys: [String], aggregate: ZSetAggregate = .sum) throws -> Int {
        try zComboStore(dst: dst, keys: keys, aggregate: aggregate, intersect: true)
    }

    // MARK: - ZSCAN

    public func zscan(key: String, cursor: Int = 0, match: String? = nil, count: Int? = nil) throws -> (Int, [(Data, Double)]) {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                return (0, [])
            }
            let all: [(Data, Double)] = try conn.run(
                "SELECT elem, score FROM rzset WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    (SQLiteConnection.columnBlob(stmt, 0), sqlite3_column_double(stmt, 1))
                }
            )
            _ = cursor; _ = count
            if let pattern = match, !pattern.isEmpty {
                let regex = try KeyStore.compileGlob(pattern)
                let filtered = all.filter { pair in
                    guard let s = String(data: pair.0, encoding: .utf8) else { return false }
                    let ns = s as NSString
                    return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
                }
                return (0, filtered)
            }
            return (0, all)
        }
    }

    // MARK: - Helpers

    private func mutateZSet<T>(key: String, _ body: (SQLiteConnection, Int64) throws -> T) throws -> T {
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
                if let t = existing.first, t != RedkaType.zset.rawValue {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .zset)
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

    static func countZSet(conn: SQLiteConnection, kid: Int64) throws -> Int {
        let rows: [Int64] = try conn.run(
            "SELECT COUNT(*) FROM rzset WHERE kid = ?",
            bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
            rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
        )
        return Int(rows.first ?? 0)
    }

    static func dropZSetIfEmpty(conn: SQLiteConnection, kid: Int64) throws {
        if try countZSet(conn: conn, kid: kid) == 0 {
            try conn.run(
                "DELETE FROM rkey WHERE id = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { _ in () }
            )
        }
    }

    private func zComboStore(dst: String,
                             keys: [String],
                             aggregate: ZSetAggregate,
                             intersect: Bool) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                // Load each input set's (elem -> score) dict.
                var dicts: [[Data: Double]] = []
                for key in keys {
                    guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .zset) else {
                        dicts.append([:])
                        continue
                    }
                    let rows: [(Data, Double)] = try conn.run(
                        "SELECT elem, score FROM rzset WHERE kid = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { stmt in
                            (SQLiteConnection.columnBlob(stmt, 0),
                             sqlite3_column_double(stmt, 1))
                        }
                    )
                    dicts.append(Dictionary(uniqueKeysWithValues: rows))
                }
                let result = ZSetMath.combine(dicts: dicts,
                                              aggregate: aggregate,
                                              intersect: intersect)
                // Replace dst.
                try conn.run(
                    "DELETE FROM rkey WHERE key = ?",
                    bind: { stmt in SQLiteConnection.bindText(stmt, 1, dst) },
                    rowMap: { _ in () }
                )
                if result.isEmpty {
                    try conn.exec("COMMIT")
                    return 0
                }
                try Self.upsertKeyLocked(conn: conn, key: dst, type: .zset)
                let kid = try Self.fetchKidLocked(conn: conn, key: dst)
                for (elem, score) in result {
                    try conn.run(
                        "INSERT INTO rzset (kid, elem, score) VALUES (?, ?, ?)",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, elem)
                            sqlite3_bind_double(stmt, 3, score)
                        },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return result.count
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }
}

enum ZSetMath {
    static func combine(dicts: [[Data: Double]],
                        aggregate: KeyStore.ZSetAggregate,
                        intersect: Bool) -> [(Data, Double)] {
        guard let first = dicts.first else { return [] }
        var working: [Data: Double] = first
        for d in dicts.dropFirst() {
            if intersect {
                var next: [Data: Double] = [:]
                for (k, v) in working {
                    if let other = d[k] {
                        next[k] = combineScalars(v, other, aggregate: aggregate)
                    }
                }
                working = next
            } else {
                for (k, v) in d {
                    if let existing = working[k] {
                        working[k] = combineScalars(existing, v, aggregate: aggregate)
                    } else {
                        working[k] = v
                    }
                }
            }
        }
        return working.map { ($0.key, $0.value) }
    }

    private static func combineScalars(_ a: Double, _ b: Double,
                                       aggregate: KeyStore.ZSetAggregate) -> Double {
        switch aggregate {
        case .sum: return a + b
        case .min: return Swift.min(a, b)
        case .max: return Swift.max(a, b)
        }
    }
}
