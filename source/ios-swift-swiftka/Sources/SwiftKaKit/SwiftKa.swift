import Csqlite3
import Foundation

/// Public surface of swiftka.
public enum SwiftKa {
    /// Semantic version of the swiftka project itself.
    public static let version = "0.13.0"

    /// Compiled-in SQLite version string (e.g. `"3.47.1"`).
    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }

    /// Reports whether the vendored SQLite has working FTS5, JSON1,
    /// and RTREE — the three optional modules swiftka relies on. Probed
    /// functionally (run a tiny statement that depends on each) rather
    /// than via `sqlite3_compileoption_used`, because some features
    /// (JSON1 since 3.38) are built in by default and no longer report
    /// a compile-option flag even though they work.
    public static var sqliteFeatures: (fts5: Bool, json1: Bool, rtree: Bool) {
        (fts5: probeFTS5(), json1: probeJSON1(), rtree: probeRTREE())
    }

    private static func probeFTS5() -> Bool {
        probe("CREATE VIRTUAL TABLE _probe_fts USING fts5(x);")
    }

    private static func probeJSON1() -> Bool {
        probe("SELECT json_extract('{\"a\":1}', '$.a');")
    }

    private static func probeRTREE() -> Bool {
        probe("CREATE VIRTUAL TABLE _probe_rt USING rtree(id, x0, x1);")
    }

    private static func probe(_ sql: String) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &db, flags, nil) == SQLITE_OK,
              let h = db else {
            if let d = db { sqlite3_close(d) }
            return false
        }
        defer { sqlite3_close(h) }
        return sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK
    }
}
