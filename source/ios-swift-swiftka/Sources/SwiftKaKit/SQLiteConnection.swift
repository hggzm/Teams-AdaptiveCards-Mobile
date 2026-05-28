import Csqlite3
import Foundation

/// Thin Swift wrapper over a single SQLite connection. Phase 2 only
/// supports `open`, `exec`, `query(rowMap:)`, and `close`. Subsequent
/// phases extend this with prepared-statement caching, the connection
/// pool (one writer + N readers), and the WAL-mode setup.
public final class SQLiteConnection {
    /// SQLITE_TRANSIENT is `((sqlite3_destructor_type)-1)` in C; that
    /// macro isn't importable so we synthesise it via `unsafeBitCast`
    /// per /memories/swift-sqlite-cross-platform.md.
    public static let TRANSIENT = unsafeBitCast(
        Int(-1),
        to: sqlite3_destructor_type.self
    )

    public enum Error: Swift.Error, CustomStringConvertible {
        case open(String, Int32)
        case exec(String, Int32, String)
        case prepare(String, Int32, String)
        case step(String, Int32, String)

        public var description: String {
            switch self {
            case .open(let path, let rc):
                return "sqlite3_open_v2(\(path)) failed: rc=\(rc)"
            case .exec(let sql, let rc, let msg):
                return "exec(\(sql)) failed: rc=\(rc) msg=\(msg)"
            case .prepare(let sql, let rc, let msg):
                return "prepare(\(sql)) failed: rc=\(rc) msg=\(msg)"
            case .step(let sql, let rc, let msg):
                return "step(\(sql)) failed: rc=\(rc) msg=\(msg)"
            }
        }
    }

    private var handle: OpaquePointer?

    /// Opens a SQLite database. Path `":memory:"` opens a private
    /// in-memory database (used in tests).
    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            if let db = db { sqlite3_close(db) }
            throw Error.open(path, rc)
        }
        self.handle = opened
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    /// Executes one or more SQL statements that return no rows.
    public func exec(_ sql: String) throws {
        guard let h = handle else { return }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "(no message)"
            if let err = err { sqlite3_free(err) }
            throw Error.exec(sql, rc, msg)
        }
    }

    /// Runs a SELECT, mapping each row via `rowMap`. The callback
    /// receives an opaque statement pointer; use `column*` helpers.
    public func query<T>(
        _ sql: String,
        rowMap: (OpaquePointer) -> T
    ) throws -> [T] {
        guard let h = handle else { return [] }
        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(h, sql, -1, &stmt, nil)
        guard prc == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw Error.prepare(sql, prc, msg)
        }
        defer { sqlite3_finalize(s) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                rows.append(rowMap(s))
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(h))
                throw Error.step(sql, rc, msg)
            }
        }
        return rows
    }

    /// Reads a `TEXT` column as Swift `String`.
    public static func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cstr)
    }

    /// Reads an `INTEGER` column as Swift `Int64`.
    public static func columnInt64(_ stmt: OpaquePointer, _ idx: Int32) -> Int64 {
        sqlite3_column_int64(stmt, idx)
    }

    /// Reads a `BLOB` (or `TEXT` as bytes) column as Swift `Data`.
    public static func columnBlob(_ stmt: OpaquePointer, _ idx: Int32) -> Data {
        let n = sqlite3_column_bytes(stmt, idx)
        guard n > 0, let ptr = sqlite3_column_blob(stmt, idx) else { return Data() }
        return Data(bytes: ptr, count: Int(n))
    }

    /// Returns true if the column at `idx` is SQL NULL.
    public static func columnIsNull(_ stmt: OpaquePointer, _ idx: Int32) -> Bool {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL
    }

    /// Number of rows affected by the most recent INSERT/UPDATE/DELETE.
    public func changes() -> Int {
        guard let h = handle else { return 0 }
        return Int(sqlite3_changes(h))
    }

    /// rowid of the last successful INSERT.
    public func lastInsertRowid() -> Int64 {
        guard let h = handle else { return 0 }
        return sqlite3_last_insert_rowid(h)
    }

    /// Reusable bound-parameter execution.
    ///
    /// `bind` is invoked once with the prepared statement, then the
    /// statement is stepped until it returns `SQLITE_DONE`. Rows are
    /// streamed through `rowMap`. Use this for SELECTs **and**
    /// parameterised mutations — for the latter pass `rowMap: { _ in () }`
    /// and ignore the returned array.
    @discardableResult
    public func run<T>(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        rowMap: (OpaquePointer) -> T
    ) throws -> [T] {
        guard let h = handle else { return [] }
        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(h, sql, -1, &stmt, nil)
        guard prc == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw Error.prepare(sql, prc, msg)
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                rows.append(rowMap(s))
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(h))
                throw Error.step(sql, rc, msg)
            }
        }
        return rows
    }

    /// Bind a Swift `String` to a `?`-parameter at 1-based `index`.
    public static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, TRANSIENT)
    }

    /// Bind a Swift `Data` to a `?`-parameter at 1-based `index`. An
    /// empty Data still binds an empty blob (not NULL).
    public static func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { raw -> Void in
            let base = raw.baseAddress
            sqlite3_bind_blob(stmt, index, base, Int32(value.count), TRANSIENT)
        }
    }

    /// Bind an `Int64` to a `?`-parameter at 1-based `index`.
    public static func bindInt64(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    /// Bind `NULL` to a `?`-parameter at 1-based `index`.
    public static func bindNull(_ stmt: OpaquePointer, _ index: Int32) {
        sqlite3_bind_null(stmt, index)
    }
}
