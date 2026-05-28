import Csqlite3
import Foundation

/// Type tag used in the redka-byte-identical `rkey.type` column.
public enum RedkaType: Int32, Sendable {
    case string = 1
    case list   = 2
    case set    = 3
    case hash   = 4
    case zset   = 5
    /// swiftka extension — Redis-compatible streams stored in the
    /// swiftka-only `rxstream` table. Not part of redka.
    case stream = 6

    /// Wire-level name used by `TYPE`.
    public var wireName: String {
        switch self {
        case .string: return "string"
        case .list:   return "list"
        case .set:    return "set"
        case .hash:   return "hash"
        case .zset:   return "zset"
        case .stream: return "stream"
        }
    }
}

/// Owns the long-lived SQLite connection and the schema lifecycle.
///
/// The schema lifted verbatim from `nalgeon/redka@main`
/// `internal/sqlx/sqlite.sql` (`pragma user_version = 1`). Keeping the
/// schema byte-identical is a deliberate compatibility feature: a
/// database file written by either project can be read by the other.
public final class Database: @unchecked Sendable {
    public let connection: SQLiteConnection
    private let lock = NSLock()

    public init(path: String) throws {
        self.connection = try SQLiteConnection(path: path)
        try applyPragmas()
        try migrate()
    }

    /// Serialises access to `connection`. SQLite at THREADSAFE=2 is
    /// safe to call concurrently from different threads on different
    /// connections; on the same connection we serialise here.
    public func withLock<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(connection)
    }

    private func applyPragmas() throws {
        try connection.exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA temp_store = MEMORY;
            PRAGMA foreign_keys = ON;
        """)
    }

    /// Schema migration. The DDL is fully idempotent (`CREATE TABLE IF
    /// NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`), so re-running it on
    /// an already-migrated database is safe and picks up tables that
    /// were added in later swiftka releases (e.g. `rxstream` from
    /// Phase 20). `user_version` is still bumped to its target value
    /// so future incompatible migrations have a sentinel to gate on.
    private func migrate() throws {
        let current = try currentUserVersion()
        guard current <= 1 else {
            throw Database.Error.unsupportedSchema(current)
        }
        try connection.exec(Database.schemaSQL)
        if current == 0 {
            try connection.exec("PRAGMA user_version = 1")
        }
    }

    private func currentUserVersion() throws -> Int32 {
        let rows = try connection.query("PRAGMA user_version") { stmt in
            Int32(sqlite3_column_int(stmt, 0))
        }
        return rows.first ?? 0
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedSchema(Int32)
        public var description: String {
            switch self {
            case .unsupportedSchema(let v):
                return "swiftka cannot open database with user_version=\(v) (max supported = 1)"
            }
        }
    }

    /// The redka-byte-identical schema (matches
    /// `nalgeon/redka@main:internal/sqlx/sqlite.sql` for the rkey,
    /// rstring, rlist, rset, rhash, rzset surfaces). Subsequent phases
    /// rely on the same SQL so a file written by either project is
    /// readable by the other.
    public static let schemaSQL: String = """
    -- ┌───────────────┐
    -- │ Keys          │
    -- └───────────────┘
    create table if not exists
    rkey (
        id       integer primary key,
        key      text not null,
        type     integer not null,
        version  integer not null,
        etime    integer,
        mtime    integer not null,
        len      integer
    ) strict;

    create unique index if not exists
    rkey_key_idx on rkey (key);

    create index if not exists
    rkey_etime_idx on rkey (etime) where etime is not null;

    -- ┌───────────────┐
    -- │ Strings       │
    -- └───────────────┘
    create table if not exists
    rstring (
        kid    integer not null,
        value  blob not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rstring_pk_idx on rstring (kid);

    -- ┌───────────────┐
    -- │ Lists         │
    -- └───────────────┘
    create table if not exists
    rlist (
        kid    integer not null,
        pos    real not null,
        elem   blob not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rlist_pk_idx on rlist (kid, pos);

    -- ┌───────────────┐
    -- │ Sets          │
    -- └───────────────┘
    create table if not exists
    rset (
        kid    integer not null,
        elem   blob not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rset_pk_idx on rset (kid, elem);

    -- ┌───────────────┐
    -- │ Hashes        │
    -- └───────────────┘
    create table if not exists
    rhash (
        kid   integer not null,
        field text not null,
        value blob not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rhash_pk_idx on rhash (kid, field);

    -- ┌───────────────┐
    -- │ Sorted sets   │
    -- └───────────────┘
    create table if not exists
    rzset (
        kid    integer not null,
        elem   blob not null,
        score  real not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rzset_pk_idx on rzset (kid, elem);

    create index if not exists
    rzset_score_idx on rzset (kid, score, elem);

    -- ┌───────────────┐
    -- │ Streams       │
    -- └───────────────┘
    -- swiftka extension on top of the redka schema. Streams are NOT
    -- part of nalgeon/redka — this is a swiftka-only table. The
    -- (kid, ms, seq, field) tuple is unique; multiple fields share a
    -- single stream entry by reusing the same (ms, seq).
    create table if not exists
    rxstream (
        kid    integer not null,
        ms     integer not null,
        seq    integer not null,
        field  text not null,
        value  blob not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rxstream_pk_idx on rxstream (kid, ms, seq, field);

    create index if not exists
    rxstream_id_idx on rxstream (kid, ms, seq);

    -- Stream consumer groups (Phase 23). Also swiftka-only.
    -- One row per (stream key, group name); last_delivered_* tracks
    -- the highest ID delivered to any consumer via XREADGROUP.
    create table if not exists
    rxstream_group (
        kid                integer not null,
        name               text not null,
        last_delivered_ms  integer not null,
        last_delivered_seq integer not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rxstream_group_pk_idx on rxstream_group (kid, name);

    -- Pending Entries List: one row per (stream, group, entry id) for
    -- every entry that's been delivered to some consumer but not yet
    -- acknowledged with XACK.
    create table if not exists
    rxstream_pel (
        kid          integer not null,
        group_name   text not null,
        ms           integer not null,
        seq          integer not null,
        consumer     text not null,
        deliveries   integer not null,
        delivered_ms integer not null,
        foreign key (kid) references rkey (id) on delete cascade
    ) strict;

    create unique index if not exists
    rxstream_pel_pk_idx on rxstream_pel (kid, group_name, ms, seq);

    create index if not exists
    rxstream_pel_consumer_idx on rxstream_pel (kid, group_name, consumer);
    """
}
