import Csqlite3
import Foundation

/// Phase 6 — string-typed commands that share the `rkey` + `rstring`
/// surface with ``KeyStore``. Bundled here as a separate file so the
/// command set is easy to audit but the storage path is identical
/// (same connection, same lock, same transactional discipline).
extension KeyStore {

    // MARK: - APPEND

    /// Appends `value` to the string stored at `key` (creating the key
    /// if missing). Returns the new total length.
    public func append(key: String, value: Data) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let existing = try Self.fetchStringValueLocked(conn: conn, key: key)
                let combined: Data
                switch existing {
                case .missing:
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    combined = value
                case .wrongType:
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                case .value(let v):
                    combined = v + value
                }
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, combined)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return combined.count
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - INCR / DECR family

    public func incr(key: String) throws -> Int64 { try incrBy(key: key, delta: 1) }
    public func decr(key: String) throws -> Int64 { try incrBy(key: key, delta: -1) }
    public func decrBy(key: String, delta: Int64) throws -> Int64 { try incrBy(key: key, delta: -delta) }

    public func incrBy(key: String, delta: Int64) throws -> Int64 {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let existing = try Self.fetchStringValueLocked(conn: conn, key: key)
                let current: Int64
                switch existing {
                case .missing:
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    current = 0
                case .wrongType:
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                case .value(let v):
                    guard let s = String(data: v, encoding: .utf8),
                          let i = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                        try conn.exec("ROLLBACK")
                        throw KeyStoreError.notInteger
                    }
                    current = i
                }
                let (next, overflow) = current.addingReportingOverflow(delta)
                if overflow {
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.overflow
                }
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                let bytes = Data(String(next).utf8)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, bytes)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return next
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - STRLEN

    /// Returns the length in bytes of the string stored at `key`, or 0
    /// if the key is missing. Throws WRONGTYPE if the key is not a
    /// string.
    public func strlen(key: String) throws -> Int {
        try database.withLock { conn in
            switch try Self.fetchStringValueLocked(conn: conn, key: key) {
            case .missing:        return 0
            case .wrongType:      throw KeyStoreError.wrongType
            case .value(let v):   return v.count
            }
        }
    }

    // MARK: - GETRANGE / SETRANGE

    /// `GETRANGE key start end` — both indices inclusive, negatives
    /// count from the end. Empty for missing keys. Matches Redis.
    public func getRange(key: String, start: Int, end: Int) throws -> Data {
        try database.withLock { conn in
            switch try Self.fetchStringValueLocked(conn: conn, key: key) {
            case .missing:      return Data()
            case .wrongType:    throw KeyStoreError.wrongType
            case .value(let v):
                let n = v.count
                if n == 0 { return Data() }
                var lo = start, hi = end
                if lo < 0 { lo = max(0, n + lo) }
                if hi < 0 { hi = n + hi }
                lo = max(0, lo)
                hi = min(n - 1, hi)
                if lo > hi { return Data() }
                return v.subdata(in: lo..<(hi + 1))
            }
        }
    }

    /// `SETRANGE key offset value` — pads with zero bytes if needed.
    /// Returns the new total length.
    @discardableResult
    public func setRange(key: String, offset: Int, value: Data) throws -> Int {
        guard offset >= 0 else { throw KeyStoreError.invalidOffset }
        return try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let existing = try Self.fetchStringValueLocked(conn: conn, key: key)
                var bytes: Data
                switch existing {
                case .missing:
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    bytes = Data()
                case .wrongType:
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                case .value(let v):
                    bytes = v
                }
                let needed = offset + value.count
                if bytes.count < needed {
                    bytes.append(Data(repeating: 0, count: needed - bytes.count))
                }
                bytes.replaceSubrange(offset..<(offset + value.count), with: value)
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, bytes)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return bytes.count
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - GETSET / GETDEL / GETEX

    /// Atomically sets `key` to `value` and returns the previous value.
    public func getSet(key: String, value: Data) throws -> Data? {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let prev: Data?
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing:      prev = nil
                case .wrongType:    try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                case .value(let v): prev = v
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, value)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return prev
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Gets the value at `key` and deletes the key in one transaction.
    public func getDel(key: String) throws -> Data? {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let result: Data?
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing:      result = nil
                case .wrongType:    try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                case .value(let v): result = v
                }
                if result != nil {
                    try conn.run(
                        "DELETE FROM rkey WHERE key = ?",
                        bind: { stmt in SQLiteConnection.bindText(stmt, 1, key) },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return result
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Options accepted by ``getEx(key:option:)``.
    public enum GetExOption: Sendable, Equatable {
        case persist                    // PERSIST
        case ex(Int64)                  // EX seconds
        case px(Int64)                  // PX milliseconds
        case exAt(Int64)                // EXAT unix-seconds
        case pxAt(Int64)                // PXAT unix-milliseconds
        case none                       // no flag
    }

    /// `GETEX key [EX|PX|EXAT|PXAT n | PERSIST]`. Reads the value and
    /// optionally rewrites the expiry on `rkey.etime`.
    public func getEx(key: String, option: GetExOption = .none) throws -> Data? {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let value: Data?
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing:      value = nil
                case .wrongType:    try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                case .value(let v): value = v
                }
                if value != nil {
                    try Self.applyExpiryLocked(conn: conn, key: key, option: option)
                }
                try conn.exec("COMMIT")
                return value
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - MGET / MSET / MSETNX

    /// Returns one value per key; missing/wrong-type entries become
    /// `nil` (matching Redis MGET semantics).
    public func mget(keys: [String]) throws -> [Data?] {
        try database.withLock { conn in
            try keys.map { key in
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing, .wrongType: return nil
                case .value(let v):        return v
                }
            }
        }
    }

    /// Atomically sets multiple key/value pairs. Returns nothing.
    public func mset(pairs: [(String, Data)]) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                for (key, value) in pairs {
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    let kid = try Self.fetchKidLocked(conn: conn, key: key)
                    try conn.run(
                        "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, value)
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

    /// Sets all pairs only if none of the keys already exist. Returns
    /// `true` on success, `false` if any key existed.
    public func msetnx(pairs: [(String, Data)]) throws -> Bool {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                for (key, _) in pairs {
                    let exists: [Int64] = try conn.run(
                        "SELECT 1 FROM rkey WHERE key = ? AND (etime IS NULL OR etime > ?)",
                        bind: { stmt in
                            SQLiteConnection.bindText(stmt, 1, key)
                            SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                        },
                        rowMap: { _ in 1 }
                    )
                    if !exists.isEmpty {
                        try conn.exec("ROLLBACK")
                        return false
                    }
                }
                for (key, value) in pairs {
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    let kid = try Self.fetchKidLocked(conn: conn, key: key)
                    try conn.run(
                        "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, value)
                        },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return true
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - SETNX / SETEX / PSETEX

    /// Sets the key only if it doesn't already exist. Returns true on
    /// success.
    public func setnx(key: String, value: Data) throws -> Bool {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let exists: [Int64] = try conn.run(
                    "SELECT 1 FROM rkey WHERE key = ? AND (etime IS NULL OR etime > ?)",
                    bind: { stmt in
                        SQLiteConnection.bindText(stmt, 1, key)
                        SQLiteConnection.bindInt64(stmt, 2, Self.nowMSStatic())
                    },
                    rowMap: { _ in 1 }
                )
                if !exists.isEmpty {
                    try conn.exec("ROLLBACK")
                    return false
                }
                try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, value)
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

    /// `SETEX key seconds value` — set with TTL in seconds.
    public func setex(key: String, seconds: Int64, value: Data) throws {
        try setWithTTL(key: key, value: value, expiryMS: Self.nowMSStatic() + seconds * 1000)
    }

    /// `PSETEX key milliseconds value` — set with TTL in milliseconds.
    public func psetex(key: String, milliseconds: Int64, value: Data) throws {
        try setWithTTL(key: key, value: value, expiryMS: Self.nowMSStatic() + milliseconds)
    }

    private func setWithTTL(key: String, value: Data, expiryMS: Int64) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                try Self.upsertKeyLocked(conn: conn, key: key, type: .string, etime: expiryMS)
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, value)
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

    // MARK: - Helpers (file-private to extension)

    /// Result of probing the (rkey, rstring) join for a key.
    enum StringFetchResult {
        case missing
        case wrongType
        case value(Data)
    }

    static func nowMSStatic() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Reads the string value at `key` while a lock is already held.
    static func fetchStringValueLocked(conn: SQLiteConnection,
                                       key: String) throws -> StringFetchResult {
        let rows: [(Int32, Data, Bool)] = try conn.run(
            """
            SELECT rkey.type,
                   COALESCE(rstring.value, x''),
                   rstring.kid IS NULL
            FROM rkey LEFT JOIN rstring ON rstring.kid = rkey.id
            WHERE rkey.key = ?
              AND (rkey.etime IS NULL OR rkey.etime > ?)
            """,
            bind: { stmt in
                SQLiteConnection.bindText(stmt, 1, key)
                SQLiteConnection.bindInt64(stmt, 2, nowMSStatic())
            },
            rowMap: { stmt in
                (Int32(SQLiteConnection.columnInt64(stmt, 0)),
                 SQLiteConnection.columnBlob(stmt, 1),
                 SQLiteConnection.columnInt64(stmt, 2) != 0)
            }
        )
        guard let (t, value, missingValue) = rows.first else { return .missing }
        if t != RedkaType.string.rawValue { return .wrongType }
        // rkey present, type=string — rstring row may legitimately be
        // missing (e.g. SET without value, shouldn't happen, but be
        // defensive). Treat as empty string.
        return missingValue ? .value(Data()) : .value(value)
    }

    /// Upserts the rkey row (and clears or sets the expiry).
    static func upsertKeyLocked(conn: SQLiteConnection,
                                key: String,
                                type: RedkaType,
                                etime: Int64? = nil) throws {
        let now = nowMSStatic()
        try conn.run(
            """
            INSERT INTO rkey (key, type, version, etime, mtime, len)
            VALUES (?, ?, 1, ?, ?, NULL)
            ON CONFLICT(key) DO UPDATE SET
                type    = excluded.type,
                version = rkey.version + 1,
                etime   = excluded.etime,
                mtime   = excluded.mtime
            """,
            bind: { stmt in
                SQLiteConnection.bindText(stmt, 1, key)
                SQLiteConnection.bindInt64(stmt, 2, Int64(type.rawValue))
                if let e = etime {
                    SQLiteConnection.bindInt64(stmt, 3, e)
                } else {
                    SQLiteConnection.bindNull(stmt, 3)
                }
                SQLiteConnection.bindInt64(stmt, 4, now)
            },
            rowMap: { _ in () }
        )
    }

    static func fetchKidLocked(conn: SQLiteConnection, key: String) throws -> Int64 {
        let rows: [Int64] = try conn.run(
            "SELECT id FROM rkey WHERE key = ?",
            bind: { stmt in SQLiteConnection.bindText(stmt, 1, key) },
            rowMap: { stmt in SQLiteConnection.columnInt64(stmt, 0) }
        )
        guard let id = rows.first else { throw KeyStoreError.noSuchKey }
        return id
    }

    static func applyExpiryLocked(conn: SQLiteConnection,
                                  key: String,
                                  option: GetExOption) throws {
        let now = nowMSStatic()
        let newEtime: Int64?
        switch option {
        case .none:    return                 // leave existing etime alone
        case .persist: newEtime = nil
        case .ex(let s):    newEtime = now + s * 1000
        case .px(let ms):   newEtime = now + ms
        case .exAt(let s):  newEtime = s * 1000
        case .pxAt(let ms): newEtime = ms
        }
        try conn.run(
            "UPDATE rkey SET etime = ?, mtime = ?, version = version + 1 WHERE key = ?",
            bind: { stmt in
                if let e = newEtime {
                    SQLiteConnection.bindInt64(stmt, 1, e)
                } else {
                    SQLiteConnection.bindNull(stmt, 1)
                }
                SQLiteConnection.bindInt64(stmt, 2, now)
                SQLiteConnection.bindText(stmt, 3, key)
            },
            rowMap: { _ in () }
        )
    }
}

extension KeyStoreError {
    public static let notInteger = KeyStoreError.appError("ERR value is not an integer or out of range")
    public static let overflow   = KeyStoreError.appError("ERR increment or decrement would overflow")
    public static let invalidOffset = KeyStoreError.appError("ERR offset is out of range")
}
