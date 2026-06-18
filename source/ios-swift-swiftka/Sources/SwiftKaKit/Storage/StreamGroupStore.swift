import Csqlite3
import Foundation

/// Phase 23 — Stream consumer groups.
///
/// XGROUP CREATE/SETID/DESTROY/CREATECONSUMER/DELCONSUMER manage the
/// `rxstream_group` and `rxstream_pel` tables. XREADGROUP delivers
/// entries with id > group's last_delivered to the named consumer,
/// recording each delivery in the Pending Entries List (PEL). XACK
/// removes PEL entries. XPENDING / XCLAIM / XAUTOCLAIM / XINFO surface
/// the PEL for ops tooling.
extension KeyStore {

    public struct StreamGroup: Sendable {
        public var name: String
        public var lastDeliveredMs: Int64
        public var lastDeliveredSeq: Int64
    }

    public struct StreamPELEntry: Sendable {
        public var ms: Int64
        public var seq: Int64
        public var consumer: String
        public var deliveries: Int
        public var deliveredMs: Int64
        public var id: String { "\(ms)-\(seq)" }
    }

    // MARK: - XGROUP

    /// `XGROUP CREATE key group id [MKSTREAM]`.
    public func xgroupCreate(key: String,
                             group: String,
                             startId: (Int64, Int64),
                             mkstream: Bool) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let kid: Int64
                if let existing = try Self.fetchKidForType(conn: conn, key: key, type: .stream) {
                    kid = existing
                } else if mkstream {
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .stream)
                    kid = try Self.fetchKidLocked(conn: conn, key: key)
                } else {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("ERR The XGROUP subcommand requires the key to exist. Note that for CREATE you may want to use the MKSTREAM option to create an empty stream automatically.")
                }
                // Resolve `$` to the stream's current top id.
                let resolved: (Int64, Int64)
                if startId.0 == Int64.max && startId.1 == Int64.max {
                    let topRows: [(Int64, Int64)] = try conn.run(
                        "SELECT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms DESC, seq DESC LIMIT 1",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { stmt in
                            (SQLiteConnection.columnInt64(stmt, 0),
                             SQLiteConnection.columnInt64(stmt, 1))
                        }
                    )
                    resolved = topRows.first ?? (0, 0)
                } else {
                    resolved = startId
                }
                // Reject if group already exists.
                let exists: [Int64] = try conn.run(
                    "SELECT 1 FROM rxstream_group WHERE kid = ? AND name = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                    },
                    rowMap: { _ in 1 }
                )
                if !exists.isEmpty {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("BUSYGROUP Consumer Group name already exists")
                }
                try conn.run(
                    "INSERT INTO rxstream_group (kid, name, last_delivered_ms, last_delivered_seq) VALUES (?, ?, ?, ?)",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                        SQLiteConnection.bindInt64(stmt, 3, resolved.0)
                        SQLiteConnection.bindInt64(stmt, 4, resolved.1)
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

    public func xgroupSetId(key: String, group: String, id: (Int64, Int64)) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("ERR no such key")
                }
                let resolved: (Int64, Int64)
                if id.0 == Int64.max && id.1 == Int64.max {
                    let topRows: [(Int64, Int64)] = try conn.run(
                        "SELECT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms DESC, seq DESC LIMIT 1",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { stmt in
                            (SQLiteConnection.columnInt64(stmt, 0),
                             SQLiteConnection.columnInt64(stmt, 1))
                        }
                    )
                    resolved = topRows.first ?? (0, 0)
                } else {
                    resolved = id
                }
                try conn.run(
                    "UPDATE rxstream_group SET last_delivered_ms = ?, last_delivered_seq = ? WHERE kid = ? AND name = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, resolved.0)
                        SQLiteConnection.bindInt64(stmt, 2, resolved.1)
                        SQLiteConnection.bindInt64(stmt, 3, kid)
                        SQLiteConnection.bindText(stmt, 4, group)
                    },
                    rowMap: { _ in () }
                )
                if conn.changes() == 0 {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.appError("NOGROUP No such consumer group '\(group)' for key name '\(key)'")
                }
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Returns the number of groups removed (0 or 1).
    public func xgroupDestroy(key: String, group: String) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK")
                    return 0
                }
                try conn.run(
                    "DELETE FROM rxstream_pel WHERE kid = ? AND group_name = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                    },
                    rowMap: { _ in () }
                )
                try conn.run(
                    "DELETE FROM rxstream_group WHERE kid = ? AND name = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                    },
                    rowMap: { _ in () }
                )
                let removed = conn.changes()
                try conn.exec("COMMIT")
                return removed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Returns the number of pending entries removed for the consumer.
    /// (XGROUP DELCONSUMER's Redis return value.)
    @discardableResult
    public func xgroupDelConsumer(key: String, group: String, consumer: String) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK")
                    return 0
                }
                try conn.run(
                    "DELETE FROM rxstream_pel WHERE kid = ? AND group_name = ? AND consumer = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                        SQLiteConnection.bindText(stmt, 3, consumer)
                    },
                    rowMap: { _ in () }
                )
                let removed = conn.changes()
                try conn.exec("COMMIT")
                return removed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - XREADGROUP

    /// `XREADGROUP GROUP <g> <consumer> [COUNT n] STREAMS key id`.
    /// `id` is the per-stream ID — `>` means "new messages since the
    /// group's last_delivered", anything else means "previously-delivered
    /// messages in this consumer's PEL with id >= that".
    public func xreadGroup(group: String,
                           consumer: String,
                           streams: [(String, String /* id */)],
                           count: Int? = nil) throws -> [(String, [StreamEntry])] {
        try database.withLock { conn in
            var result: [(String, [StreamEntry])] = []
            for (key, idArg) in streams {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    continue
                }
                // Look up the group.
                let groupRows: [(Int64, Int64)] = try conn.run(
                    "SELECT last_delivered_ms, last_delivered_seq FROM rxstream_group WHERE kid = ? AND name = ?",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                    },
                    rowMap: { stmt in
                        (SQLiteConnection.columnInt64(stmt, 0),
                         SQLiteConnection.columnInt64(stmt, 1))
                    }
                )
                guard let (lastMs, lastSeq) = groupRows.first else {
                    throw KeyStoreError.appError("NOGROUP No such consumer group '\(group)' for key name '\(key)'")
                }

                if idArg == ">" {
                    // Deliver new entries strictly > last_delivered.
                    let next: (Int64, Int64)
                    if lastSeq == Int64.max { next = (lastMs + 1, 0) }
                    else                    { next = (lastMs, lastSeq + 1) }
                    let entries = try xrangeRaw(conn: conn, kid: kid,
                                                start: next,
                                                end: (Int64.max, Int64.max),
                                                count: count, reverse: false)
                    if entries.isEmpty { continue }
                    // Update group's last_delivered to the last entry returned.
                    if let last = entries.last {
                        try conn.run(
                            "UPDATE rxstream_group SET last_delivered_ms = ?, last_delivered_seq = ? WHERE kid = ? AND name = ?",
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, last.ms)
                                SQLiteConnection.bindInt64(stmt, 2, last.seq)
                                SQLiteConnection.bindInt64(stmt, 3, kid)
                                SQLiteConnection.bindText(stmt, 4, group)
                            },
                            rowMap: { _ in () }
                        )
                    }
                    // Record each in the PEL (or increment deliveries
                    // if the same consumer somehow re-delivers).
                    let now = Self.nowMSStatic()
                    for e in entries {
                        try conn.run(
                            """
                            INSERT INTO rxstream_pel (kid, group_name, ms, seq, consumer, deliveries, delivered_ms)
                            VALUES (?, ?, ?, ?, ?, 1, ?)
                            ON CONFLICT(kid, group_name, ms, seq) DO UPDATE SET
                                consumer = excluded.consumer,
                                deliveries = rxstream_pel.deliveries + 1,
                                delivered_ms = excluded.delivered_ms
                            """,
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, kid)
                                SQLiteConnection.bindText(stmt, 2, group)
                                SQLiteConnection.bindInt64(stmt, 3, e.ms)
                                SQLiteConnection.bindInt64(stmt, 4, e.seq)
                                SQLiteConnection.bindText(stmt, 5, consumer)
                                SQLiteConnection.bindInt64(stmt, 6, now)
                            },
                            rowMap: { _ in () }
                        )
                    }
                    result.append((key, entries))
                } else {
                    // Re-deliver previously-delivered entries owned by
                    // this consumer with id >= idArg.
                    guard let from = StreamIDParser.parse(idArg, missingSeq: 0) else {
                        throw KeyStoreError.appError("ERR Invalid stream ID specified as stream command argument")
                    }
                    let limit = count ?? Int.max
                    let pelRows: [(Int64, Int64)] = try conn.run(
                        """
                        SELECT ms, seq FROM rxstream_pel
                        WHERE kid = ? AND group_name = ? AND consumer = ?
                          AND ((ms > ?) OR (ms = ? AND seq >= ?))
                        ORDER BY ms ASC, seq ASC
                        LIMIT ?
                        """,
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindText(stmt, 2, group)
                            SQLiteConnection.bindText(stmt, 3, consumer)
                            SQLiteConnection.bindInt64(stmt, 4, from.0)
                            SQLiteConnection.bindInt64(stmt, 5, from.0)
                            SQLiteConnection.bindInt64(stmt, 6, from.1)
                            SQLiteConnection.bindInt64(stmt, 7, Int64(limit))
                        },
                        rowMap: { stmt in
                            (SQLiteConnection.columnInt64(stmt, 0),
                             SQLiteConnection.columnInt64(stmt, 1))
                        }
                    )
                    var entries: [StreamEntry] = []
                    for (ms, seq) in pelRows {
                        let fieldRows: [(String, Data)] = try conn.run(
                            "SELECT field, value FROM rxstream WHERE kid = ? AND ms = ? AND seq = ? ORDER BY field",
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, kid)
                                SQLiteConnection.bindInt64(stmt, 2, ms)
                                SQLiteConnection.bindInt64(stmt, 3, seq)
                            },
                            rowMap: { stmt in
                                (SQLiteConnection.columnText(stmt, 0),
                                 SQLiteConnection.columnBlob(stmt, 1))
                            }
                        )
                        if !fieldRows.isEmpty {
                            entries.append(StreamEntry(ms: ms, seq: seq, fields: fieldRows))
                        }
                    }
                    if !entries.isEmpty { result.append((key, entries)) }
                }
            }
            return result
        }
    }

    // MARK: - XACK

    @discardableResult
    public func xack(key: String, group: String, ids: [(Int64, Int64)]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK")
                    return 0
                }
                var removed = 0
                for (ms, seq) in ids {
                    try conn.run(
                        "DELETE FROM rxstream_pel WHERE kid = ? AND group_name = ? AND ms = ? AND seq = ?",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindText(stmt, 2, group)
                            SQLiteConnection.bindInt64(stmt, 3, ms)
                            SQLiteConnection.bindInt64(stmt, 4, seq)
                        },
                        rowMap: { _ in () }
                    )
                    removed += conn.changes()
                }
                try conn.exec("COMMIT")
                return removed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - XPENDING

    /// `XPENDING key group` — summary form: returns total count and
    /// per-consumer counts.
    public struct XPendingSummary: Sendable {
        public var total: Int
        public var minId: (Int64, Int64)?
        public var maxId: (Int64, Int64)?
        public var perConsumer: [(String, Int)]
    }

    public func xpendingSummary(key: String, group: String) throws -> XPendingSummary {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                return XPendingSummary(total: 0, minId: nil, maxId: nil, perConsumer: [])
            }
            let totals: [(Int64, Int64, Int64, Int64, Int64)] = try conn.run(
                """
                SELECT COUNT(*), COALESCE(MIN(ms),0), COALESCE(MIN(seq),0),
                                COALESCE(MAX(ms),0), COALESCE(MAX(seq),0)
                FROM rxstream_pel WHERE kid = ? AND group_name = ?
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, group)
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnInt64(stmt, 1),
                     SQLiteConnection.columnInt64(stmt, 2),
                     SQLiteConnection.columnInt64(stmt, 3),
                     SQLiteConnection.columnInt64(stmt, 4))
                }
            )
            guard let first = totals.first else {
                return XPendingSummary(total: 0, minId: nil, maxId: nil, perConsumer: [])
            }
            let perConsumer: [(String, Int)] = try conn.run(
                """
                SELECT consumer, COUNT(*) FROM rxstream_pel
                WHERE kid = ? AND group_name = ?
                GROUP BY consumer ORDER BY consumer
                """,
                bind: { stmt in
                    SQLiteConnection.bindInt64(stmt, 1, kid)
                    SQLiteConnection.bindText(stmt, 2, group)
                },
                rowMap: { stmt in
                    (SQLiteConnection.columnText(stmt, 0),
                     Int(SQLiteConnection.columnInt64(stmt, 1)))
                }
            )
            let total = Int(first.0)
            return XPendingSummary(
                total: total,
                minId: total > 0 ? (first.1, first.2) : nil,
                maxId: total > 0 ? (first.3, first.4) : nil,
                perConsumer: perConsumer
            )
        }
    }

    // MARK: - XCLAIM

    /// `XCLAIM key group consumer minIdleMs id [id ...]` — transfer
    /// ownership of pending entries to a different consumer if their
    /// idle time >= minIdleMs.
    public func xclaim(key: String,
                       group: String,
                       newConsumer: String,
                       minIdleMs: Int64,
                       ids: [(Int64, Int64)]) throws -> [StreamEntry] {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK"); return []
                }
                let now = Self.nowMSStatic()
                let cutoff = now - minIdleMs
                var claimed: [StreamEntry] = []
                for (ms, seq) in ids {
                    let owners: [(String, Int64, Int64)] = try conn.run(
                        """
                        SELECT consumer, deliveries, delivered_ms FROM rxstream_pel
                        WHERE kid = ? AND group_name = ? AND ms = ? AND seq = ?
                          AND delivered_ms <= ?
                        """,
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindText(stmt, 2, group)
                            SQLiteConnection.bindInt64(stmt, 3, ms)
                            SQLiteConnection.bindInt64(stmt, 4, seq)
                            SQLiteConnection.bindInt64(stmt, 5, cutoff)
                        },
                        rowMap: { stmt in
                            (SQLiteConnection.columnText(stmt, 0),
                             SQLiteConnection.columnInt64(stmt, 1),
                             SQLiteConnection.columnInt64(stmt, 2))
                        }
                    )
                    guard let (_, deliveries, _) = owners.first else { continue }
                    try conn.run(
                        """
                        UPDATE rxstream_pel
                        SET consumer = ?, deliveries = ?, delivered_ms = ?
                        WHERE kid = ? AND group_name = ? AND ms = ? AND seq = ?
                        """,
                        bind: { stmt in
                            SQLiteConnection.bindText(stmt, 1, newConsumer)
                            SQLiteConnection.bindInt64(stmt, 2, deliveries + 1)
                            SQLiteConnection.bindInt64(stmt, 3, now)
                            SQLiteConnection.bindInt64(stmt, 4, kid)
                            SQLiteConnection.bindText(stmt, 5, group)
                            SQLiteConnection.bindInt64(stmt, 6, ms)
                            SQLiteConnection.bindInt64(stmt, 7, seq)
                        },
                        rowMap: { _ in () }
                    )
                    let fields: [(String, Data)] = try conn.run(
                        "SELECT field, value FROM rxstream WHERE kid = ? AND ms = ? AND seq = ? ORDER BY field",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindInt64(stmt, 2, ms)
                            SQLiteConnection.bindInt64(stmt, 3, seq)
                        },
                        rowMap: { stmt in
                            (SQLiteConnection.columnText(stmt, 0),
                             SQLiteConnection.columnBlob(stmt, 1))
                        }
                    )
                    if !fields.isEmpty {
                        claimed.append(StreamEntry(ms: ms, seq: seq, fields: fields))
                    }
                }
                try conn.exec("COMMIT")
                return claimed
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - XAUTOCLAIM

    /// `XAUTOCLAIM key group consumer min-idle-time start [COUNT n]`.
    /// Scans the PEL starting from `start` (inclusive) for entries
    /// idle ≥ minIdleMs, transfers up to `count` of them to
    /// `newConsumer`, and returns `(nextCursor, claimedEntries,
    /// deletedIds)`. `nextCursor == "0-0"` indicates iteration is
    /// complete.
    public func xautoclaim(key: String,
                           group: String,
                           newConsumer: String,
                           minIdleMs: Int64,
                           start: (Int64, Int64),
                           count: Int = 100) throws -> (String, [StreamEntry], [String]) {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                    try conn.exec("ROLLBACK")
                    return ("0-0", [], [])
                }
                let now = Self.nowMSStatic()
                let cutoff = now - minIdleMs
                // Pull eligible PEL rows starting at `start`, ordered.
                let pelRows: [(Int64, Int64, Int64)] = try conn.run(
                    """
                    SELECT ms, seq, deliveries FROM rxstream_pel
                    WHERE kid = ? AND group_name = ?
                      AND ((ms > ?) OR (ms = ? AND seq >= ?))
                      AND delivered_ms <= ?
                    ORDER BY ms ASC, seq ASC
                    LIMIT ?
                    """,
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindText(stmt, 2, group)
                        SQLiteConnection.bindInt64(stmt, 3, start.0)
                        SQLiteConnection.bindInt64(stmt, 4, start.0)
                        SQLiteConnection.bindInt64(stmt, 5, start.1)
                        SQLiteConnection.bindInt64(stmt, 6, cutoff)
                        SQLiteConnection.bindInt64(stmt, 7, Int64(max(1, count)))
                    },
                    rowMap: { stmt in
                        (SQLiteConnection.columnInt64(stmt, 0),
                         SQLiteConnection.columnInt64(stmt, 1),
                         SQLiteConnection.columnInt64(stmt, 2))
                    }
                )
                var claimed: [StreamEntry] = []
                var deleted: [String] = []
                for (ms, seq, deliveries) in pelRows {
                    // Check that the underlying stream entry still
                    // exists. If it doesn't (XDEL'd), drop the PEL row
                    // and add to `deleted`.
                    let fields: [(String, Data)] = try conn.run(
                        "SELECT field, value FROM rxstream WHERE kid = ? AND ms = ? AND seq = ? ORDER BY field",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindInt64(stmt, 2, ms)
                            SQLiteConnection.bindInt64(stmt, 3, seq)
                        },
                        rowMap: { stmt in
                            (SQLiteConnection.columnText(stmt, 0),
                             SQLiteConnection.columnBlob(stmt, 1))
                        }
                    )
                    if fields.isEmpty {
                        deleted.append("\(ms)-\(seq)")
                        try conn.run(
                            "DELETE FROM rxstream_pel WHERE kid = ? AND group_name = ? AND ms = ? AND seq = ?",
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, kid)
                                SQLiteConnection.bindText(stmt, 2, group)
                                SQLiteConnection.bindInt64(stmt, 3, ms)
                                SQLiteConnection.bindInt64(stmt, 4, seq)
                            },
                            rowMap: { _ in () }
                        )
                        continue
                    }
                    try conn.run(
                        """
                        UPDATE rxstream_pel
                        SET consumer = ?, deliveries = ?, delivered_ms = ?
                        WHERE kid = ? AND group_name = ? AND ms = ? AND seq = ?
                        """,
                        bind: { stmt in
                            SQLiteConnection.bindText(stmt, 1, newConsumer)
                            SQLiteConnection.bindInt64(stmt, 2, deliveries + 1)
                            SQLiteConnection.bindInt64(stmt, 3, now)
                            SQLiteConnection.bindInt64(stmt, 4, kid)
                            SQLiteConnection.bindText(stmt, 5, group)
                            SQLiteConnection.bindInt64(stmt, 6, ms)
                            SQLiteConnection.bindInt64(stmt, 7, seq)
                        },
                        rowMap: { _ in () }
                    )
                    claimed.append(StreamEntry(ms: ms, seq: seq, fields: fields))
                }
                // Compute next cursor — the id immediately after the
                // last row we touched, or "0-0" if there were none /
                // we caught up.
                let nextCursor: String
                if pelRows.isEmpty {
                    nextCursor = "0-0"
                } else if let last = pelRows.last {
                    // Bump seq by 1 to make the next call exclusive.
                    if last.1 == Int64.max {
                        nextCursor = "\(last.0 + 1)-0"
                    } else {
                        nextCursor = "\(last.0)-\(last.1 + 1)"
                    }
                } else {
                    nextCursor = "0-0"
                }
                try conn.exec("COMMIT")
                return (nextCursor, claimed, deleted)
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - XINFO STREAM / GROUPS

    public struct XInfoStream: Sendable {
        public var length: Int
        public var firstId: (Int64, Int64)?
        public var lastId: (Int64, Int64)?
        public var groupCount: Int
    }

    public func xinfoStream(key: String) throws -> XInfoStream? {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                return nil
            }
            let lenRows: [Int64] = try conn.run(
                "SELECT COUNT(DISTINCT ms || '-' || seq) FROM rxstream WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            let firstRows: [(Int64, Int64)] = try conn.run(
                "SELECT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms ASC, seq ASC LIMIT 1",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnInt64(stmt, 1))
                }
            )
            let lastRows: [(Int64, Int64)] = try conn.run(
                "SELECT ms, seq FROM rxstream WHERE kid = ? ORDER BY ms DESC, seq DESC LIMIT 1",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    (SQLiteConnection.columnInt64(stmt, 0),
                     SQLiteConnection.columnInt64(stmt, 1))
                }
            )
            let groupRows: [Int64] = try conn.run(
                "SELECT COUNT(*) FROM rxstream_group WHERE kid = ?",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
            )
            return XInfoStream(
                length: Int(lenRows.first ?? 0),
                firstId: firstRows.first,
                lastId: lastRows.first,
                groupCount: Int(groupRows.first ?? 0)
            )
        }
    }

    public func xinfoGroups(key: String) throws -> [StreamGroup] {
        try database.withLock { conn in
            guard let kid = try Self.fetchKidForType(conn: conn, key: key, type: .stream) else {
                return []
            }
            return try conn.run(
                "SELECT name, last_delivered_ms, last_delivered_seq FROM rxstream_group WHERE kid = ? ORDER BY name",
                bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                rowMap: { stmt in
                    StreamGroup(name: SQLiteConnection.columnText(stmt, 0),
                                lastDeliveredMs: SQLiteConnection.columnInt64(stmt, 1),
                                lastDeliveredSeq: SQLiteConnection.columnInt64(stmt, 2))
                }
            )
        }
    }

    // MARK: - Internals shared with XREADGROUP

    /// Same shape as the public `xrange`, but operates on an already-
    /// locked connection. Extracted so XREADGROUP can reuse it.
    private func xrangeRaw(conn: SQLiteConnection,
                           kid: Int64,
                           start: (Int64, Int64),
                           end: (Int64, Int64),
                           count: Int?,
                           reverse: Bool) throws -> [StreamEntry] {
        let order = reverse ? "DESC" : "ASC"
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
