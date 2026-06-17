import Foundation

/// A content-addressed, on-disk cache of fetched source archives, keyed by the
/// lowercase SHA-256 hex of the bytes.
///
/// This is the local half of the source-acquisition pipeline: once a source is
/// fetched and verified it is stored here, so a later build of the same package
/// reuses the cached bytes instead of re-fetching. `FileManager`-only, so it
/// behaves identically on macOS, Linux, Windows and WSL, and maps cleanly onto
/// a directory inside the iOS app's sandbox container.
public final class SourceCache {
    public let root: String
    private let fm: FileManager

    public init(root: String, fileManager: FileManager = .default) {
        self.root = root
        self.fm = fileManager
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    private func path(for sha: String) -> String {
        (root as NSString).appendingPathComponent(sha)
    }

    public func contains(_ sha: String) -> Bool {
        fm.fileExists(atPath: path(for: sha))
    }

    /// Store `data` keyed by its SHA-256; returns that hash. Idempotent.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let sha = SHA256.hexDigest(data)
        let p = path(for: sha)
        if !fm.fileExists(atPath: p) {
            try data.write(to: URL(fileURLWithPath: p))
        }
        return sha
    }

    public func load(_ sha: String) -> Data? {
        fm.contents(atPath: path(for: sha))
    }

    /// Number of cached objects.
    public func count() -> Int {
        (try? fm.contentsOfDirectory(atPath: root))?.count ?? 0
    }
}

/// The outcome of fetching one package's source.
public struct FetchResult: Equatable {
    public var package: String
    public var sha256: String
    public var byteCount: Int
    public var fromCache: Bool

    public init(package: String, sha256: String, byteCount: Int, fromCache: Bool) {
        self.package = package
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fromCache = fromCache
    }
}

/// Drives source acquisition: consult the cache, otherwise fetch via a
/// ``SourceProvider``, verify the bytes against the recipe's
/// `TERMUX_PKG_SHA256`, and cache the verified result.
public final class SourceFetcher {
    public let provider: SourceProvider
    public let cache: SourceCache?

    public init(provider: SourceProvider, cache: SourceCache? = nil) {
        self.provider = provider
        self.cache = cache
    }

    /// Fetch (or reuse cached) verified source bytes for `recipe`.
    @discardableResult
    public func fetch(_ recipe: BuildRecipe) throws -> FetchResult {
        // Cache hit: a declared, verified checksum already in the cache.
        if let declared = recipe.metadata.sha256, !declared.isEmpty,
           let cache, cache.contains(declared), let data = cache.load(declared) {
            return FetchResult(package: recipe.name, sha256: declared,
                               byteCount: data.count, fromCache: true)
        }

        let data = try provider.fetch(recipe)
        try SourceVerifier.verify(data, for: recipe)   // throws on checksum mismatch
        let sha = SHA256.hexDigest(data)
        if let cache { _ = try? cache.store(data) }
        return FetchResult(package: recipe.name, sha256: sha,
                           byteCount: data.count, fromCache: false)
    }
}
