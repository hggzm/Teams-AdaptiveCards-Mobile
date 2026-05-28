import Csqlite3
import Foundation

/// Phase 20 — Streams (`XADD` / `XLEN` / `XRANGE` / `XREVRANGE` /
/// `XREAD` / `XDEL` / `XTRIM`).
///
/// Each stream is a sequence of entries; an entry has an ID of the
/// form `ms-seq` (both Int64, both > 0) and a field/value dictionary.
/// Storage: one row per (entry, field) in `rxstream(kid, ms, seq,
/// field, value)`. IDs are strictly increasing per stream — `XADD *`
/// auto-generates an ID strictly greater than the previous one.
extension KeyStore {

    /// A single stream entry as returned by XRANGE/XREAD.
    public struct StreamEntry: Equatable, Sendable {
        public var ms: Int64
        public var seq: Int64
        public var fields: [(String, Data)]

        public var id: String { "\(ms)-\(seq)" }
        public static func == (l: StreamEntry, r: StreamEntry) -> Bool {
            l.ms == r.ms && l.seq == r.seq && l.fields.count == r.fields.count
                && zip(l.fields, r.fields).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    // MARK: - XADD

    /// `XADD key id field value [field value ...]` — appends an entry.
    /// `id == nil` means `*` (auto-generate); otherwise the explicit ID
    /// must be strictly greater than the stream's current last ID.
    /// Returns the resulting `ms-seq` ID.
    @discardableResult
    public func xadd(key: String,
                     id: (Int64, Int64)?,
                     fields: [(String, Data)]) throws -> (Int64, Int64) {
        try xaddEx(key: key, id: id, fields: fields, trim: nil, noMkStream: false)!
    }

    /// Trim specification for `XADD` / `XTRIM`.
    public enum StreamTrim: Sendable {
        /// `MAXLEN [~|=] n` — keep at most n newest entries.
        case maxLen(Int)
        /// `MINID [~|=] ms-seq` — drop entries with id < this.
        case minId(Int64, Int64)
    }

    /// Extended XADD with optional trim and NOMKSTREAM semantics.
    /// Returns the chosen ID, or `nil` when NOMKSTREAM is set and the
    /// stream doesn't exist.
    @discardableResult
    public func xaddEx(key: String,
                       id: (Int64, Int64)?,
                       fields: [(String, Data)],
                       trim: StreamTrim?,
                       noMkStream: Bool) throws -> (Int64, Int64)? {
        guard !fields.isEmpty else {
            throw KeyStoreError.appError("ERR wrong number of arguments for 'xadd' command")
        }
        // NOMKSTREAM short-circuit before opening the mutate transaction.
        if noMkStream {
            let exists = try database.withLock { conn -> Bool in
                try Self.fetchKidForType(conn: conn, key: key, type: .stream) != nil
            }
            if !exists { return nil }
        }
        return try mutateStream(key: key) { conn, kid in
            // Find current top id.
            let topRows: [(Int64, Int64)] = try conn.run(
                "SELECT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms DESC, seq DESC LIMIT 1",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnInt64(stmt, 1))
                }
            )
            let top: (Int64, Int64)? = topRows.first
            let chosen: (Int64, Int64)
            switch id {
            case .none:
                let nowMs = Self.nowMSStatic()
                if let t = top {
                    if nowMs > t.0 {
                        chosen = (nowMs, 0)
                    } else {
                        chosen = (t.0, t.1 + 1)
                    }
                } else {
                    chosen = (nowMs, 0)
                }
            case .some(let want):
                if let t = top {
                    if want.0 < t.0 || (want.0 == t.0 && want.1 <= t.1) {
                        throw KeyStoreError.appError("ERR The ID specified in XADD is equal or smaller than the target stream top item")
                    }
                }
                if want.0 < 0 || want.1 < 0 {
                    throw KeyStoreError.appError("ERR Invalid stream ID specified as stream command argument")
                }
                chosen = want
            }
            for (field, value) in fields {
                try conn.run(
                    "INSERT INTO rxstream (kid, ms, seq, field, value) VALUES (?, ?, ?, ?, ?)",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindInt64(stmt, 2, chosen.0)
                        SQLiteConnection.bindInt64(stmt, 3, chosen.1)
                        SQLiteConnection.bindText(stmt, 4, field)
                        SQLiteConnection.bindBlob(stmt, 5, value)
                    },
                    rowMap: { _ in () }
                )
            }
            // Apply inline trim if requested.
            if let trim = trim {
                switch trim {
                case .maxLen(let n):
                    let entryRows: [(Int64, Int64)] = try conn.run(
                        "SELECT DISTINCT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms ASC, seq ASC",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { stmt in
                            (SQLiteConnection.columnInt64(stmt, 0),
                             SQLiteConnection.columnInt64(stmt, 1))
                        }
                    )
                    let dropCount = max(0, entryRows.count - max(0, n))
                    for (ms, seq) in entryRows.prefix(dropCount) {
                        try conn.run(
                            "DELETE FROM rxstream WHERE kid = ? AND ms = ? AND seq = ?",
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, kid)
                                SQLiteConnection.bindInt64(stmt, 2, ms)
                                SQLiteConnection.bindInt64(stmt, 3, seq)
                            },
                            rowMap: { _ in () }
                        )
                    }
                case .minId(let ms, let seq):
                    try conn.run(
                        """
                        DELETE FROM rxstream
                        WHERE kid = ?
                          AND ((ms <  ?) OR (ms = ? AND seq < ?))
                        """,
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindInt64(stmt, 2, ms)
                            SQLiteConnection.bindInt64(stmt, 3, ms)
                            SQLiteConnection.bindInt64(stmt, 4, seq)
                        },
                        rowMap: { _ in () }
                    )
                }
            }
            return chosen
        }
    }

    // MARK: - XLEN

    public func xlen(key: String) throws -> Int {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                return 0
            }
            // COUNT distinct (ms, seq) — each entry has 1+ rows.
            let rows: [Int64] = try conn.run(
                "SELECT COUNT(DISTINCT ms || '-' || seq) FROM rxstream WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return Int(rows.first ?? 0)
        }
    }

    // MARK: - XRANGE / XREVRANGE

    /// `XRANGE key start end [COUNT n]` — `start`/`end` are full IDs
    /// `ms-seq`, or `-`/`+` shortcuts handled by the caller before
    /// invoking this method. Returns entries in ascending order.
    public func xrange(key: String,
                       start: (Int64, Int64),
                       end:   (Int64, Int64),
                       count: Int? = nil,
                       reverse: Bool = false) throws -> [StreamEntry] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                return []
            }
            let order = reverse ? "DESC" : "ASC"
            // SQLite doesn't have tuple comparison, so we synthesise it
            // by combining (ms, seq) into the WHERE clause arithmetic.
            // Use two ORs: (ms > start.0) OR (ms == start.0 AND seq >= start.1).
            let rows: [(Int64, Int64, String, Data)] = try conn.run(
                """
                SELECT ms, seq, field, value FROM rxstream
                WHERE kid = ?
                  AND ((ms >  ?) OR (ms = ? AND seq >= ?))
                  AND ((ms <  ?) OR (ms = ? AND seq <= ?))
                ORDER BY ms \(order), seq \(order)
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindInt64(stmt, 2, start.0)
                    SQLiteConnection.bindInt64(stmt, 3, start.0)
                    SQLiteConnection.bindInt64(stmt, 4, start.1)
                    SQLiteConnection.bindInt64(stmt, 5, end.0)
                    SQLiteConnection.bindInt64(stmt, 6, end.0)
                    SQLiteConnection.bindInt64(stmt, 7, end.1)
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnInt64(stmt, 1),
                     SQLiteConnection.columnText(stmt, 2),
                     SQLiteConnection.columnBlob(stmt, 3))
                }
            )
            // Group rows by (ms, seq) into entries.
            var entries: [StreamEntry] = []
            var current: StreamEntry?
            for (ms, seq, field, value) in rows {
                if let c = current, c.ms == ms, c.seq == seq {
                    current?.fields.append((field, value))
                } else {
                    if let c = current { entries.append(c) }
                    current = StreamEntry(ms: ms, seq: seq, fields: [(field, value)])
                }
            }
            if let c = current { entries.append(c) }
            if let lim = count, lim >= 0 { return Array(entries.prefix(lim)) }
            return entries
        }
    }

    // MARK: - XREAD

    /// `XREAD STREAMS key id [key id ...]` — returns entries with IDs
    /// strictly greater than the supplied IDs, per stream. The `count`
    /// parameter applies per-stream. v0 ignores `BLOCK`.
    public func xread(streams: [(String, (Int64, Int64))],
                      count: Int? = nil) throws -> [(String, [StreamEntry])] {
        try streams.compactMap { (key, after) -> (String, [StreamEntry])? in
            // After-id semantics: entries with id > (after.ms, after.seq).
            // We accomplish that by adding 1 to seq (and overflowing into ms),
            // then asking xrange for [next, (Int64.max, Int64.max)].
            let next: (Int64, Int64)
            if after.1 == Int64.max {
                next = (after.0 + 1, 0)
            } else {
                next = (after.0, after.1 + 1)
            }
            let entries = try xrange(key: key, start: next,
                                     end: (Int64.max, Int64.max),
                                     count: count)
            return entries.isEmpty ? nil : (key, entries)
        }
    }

    // MARK: - XDEL

    @discardableResult
    public func xdel(key: String, ids: [(Int64, Int64)]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK"); return 0
                }
                var removed = 0
                for (ms, seq) in ids {
                    // Each entry potentially spans multiple rows (one per field).
                    let before: [Int64] = try conn.run(
                        "SELECT COUNT(*) FROM rxstream WHERE kid = ? AND ms = ? AND seq = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindInt64(stmt, 2, ms)
                            SQLiteConnection.bindInt64(stmt, 3, seq)
                        },
                        rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
                    )
                    if (before.first ?? 0) > 0 {
                        removed += 1
                        try conn.run(
                            "DELETE FROM rxstream WHERE kid = ? AND ms = ? AND seq = ?",
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, kid)
                                SQLiteConnection.bindInt64(stmt, 2, ms)
                                SQLiteConnection.bindInt64(stmt, 3, seq)
                            },
                            rowMap: { _ in () }
                        )
                    }
                }
                // Drop the rkey row if the stream is now empty.
                let remaining: [Int64] = try conn.run(
                    "SELECT COUNT(*) FROM rxstream WHERE kid = ?",
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

    // MARK: - XTRIM

    /// `XTRIM key MAXLEN n` — keeps at most `n` newest entries.
    @discardableResult
    public func xtrim(key: String, maxLen: Int) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK"); return 0
                }
                // Count current entries.
                let entryRows: [(Int64, Int64)] = try conn.run(
                    "SELECT DISTINCT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms ASC, seq ASC",
                    bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                    rowMap: { stmt in
                        (SQLiteConnection.columnInt64(stmt, 0),
                         SQLiteConnection.columnInt64(stmt, 1))
                    }
                )
                if maxLen < 0 {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("ERR invalid maxlen")
                }
                let dropCount = max(0, entryRows.count - maxLen)
                if dropCount == 0 {
                    try conn.exec("COMMIT")
                    return 0
                }
                let toDrop = entryRows.prefix(dropCount)
                for (ms, seq) in toDrop {
                    try conn.run(
                        "DELETE FROM rxstream WHERE kid = ? AND ms = ? AND seq = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindInt64(stmt, 2, ms)
                            SQLiteConnection.bindInt64(stmt, 3, seq)
                        },
                        rowMap: { _ in () }
                    )
                }
                let remaining: [Int64] = try conn.run(
                    "SELECT COUNT(*) FROM rxstream WHERE kid = ?",
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
                return dropCount
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - Helpers

    private func mutateStream<T>(key: String,
                                 _ body: (SQLiteConnection, Int64) throws -> T) throws -> T {
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
                if let t = existing.first, t != RedkaType.stream.rawValue {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .stream)
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

// MARK: - Stream ID parsing

/// Parses a Redis-style stream ID (`ms-seq`, `ms`, `-`, `+`, `$`).
/// Returns `nil` if the input is malformed.
public enum StreamIDParser {
    /// Wildcards that resolve to the lowest possible ID.
    public static let minID: (Int64, Int64) = (0, 0)
    /// Wildcards that resolve to the highest possible ID.
    public static let maxID: (Int64, Int64) = (Int64.max, Int64.max)

    public static func parse(_ s: String,
                             missingSeq: Int64,
                             upperBoundForBareMS: Bool = false) -> (Int64, Int64)? {
        switch s {
        case "-": return minID
        case "+", "$": return maxID
        default: break
        }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let ms = Int64(parts[0]) else { return nil }
        if parts.count == 1 {
            // Bare ms — Redis semantics: lower bound uses seq=0, upper
            // bound uses seq=Int64.max.
            return (ms, upperBoundForBareMS ? Int64.max : missingSeq)
        }
        guard let seq = Int64(parts[1]) else { return nil }
        return (ms, seq)
    }
}
