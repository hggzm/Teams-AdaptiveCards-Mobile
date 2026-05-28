import Foundation
import SwiftKaKit

/// A minimal AdaptiveCards-facing surface on top of the vendored
/// swiftka kit. The store persists card JSON blobs keyed by a card
/// id and reads them back losslessly. It exists so the proxy bridge
/// has a tiny, named surface for downstream consumers (mobile hosts,
/// the symbol-check demo, etc.) to depend on without reaching into
/// `SwiftKaKit` internals directly.
public struct AdaptiveCardStore {

    /// The on-disk SQLite file backing the store. Use ":memory:" for
    /// ephemeral tests.
    public let path: String

    /// Lazily-opened storage. We open per-instance (rather than
    /// per-call) so callers can reuse the connection across multiple
    /// store/load operations.
    private let database: Database
    private let keys: KeyStore

    /// Opens (or creates) the SQLite-backed store at `path`. Set the
    /// path to `":memory:"` for ephemeral storage.
    public init(path: String) throws {
        self.path = path
        self.database = try Database(path: path)
        self.keys = KeyStore(database: self.database)
    }

    /// Persists `card` under the given `id`. Existing entries with the
    /// same id are overwritten (matches SwiftKaKit `SET` semantics).
    public func storeCard(id: String, json: Data) throws {
        try keys.set(key: id, value: json)
    }

    /// Loads the card previously stored under `id`, or returns `nil`
    /// when there is no entry. Throws on storage errors.
    public func loadCard(id: String) throws -> Data? {
        try keys.get(key: id)
    }

    /// Returns the size in bytes of the card stored under `id`, or
    /// zero when missing. Convenient for symbol-check demos that want
    /// to assert "we wrote N bytes; we read N bytes back".
    public func cardSize(id: String) throws -> Int {
        try keys.strlen(key: id)
    }
}
