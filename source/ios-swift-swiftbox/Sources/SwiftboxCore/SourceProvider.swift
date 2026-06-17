import Foundation

/// Supplies the source bytes for a recipe and verifies their integrity.
///
/// Fetching real tarballs over the network is out of scope for the sandbox-first
/// engine (and untestable offline), so source acquisition is abstracted behind
/// this protocol. Tests and the offline catalog use ``InMemorySourceProvider``;
/// a networked provider can be slotted in later without touching the builder.
public protocol SourceProvider: AnyObject {
    /// Return the raw source bytes for `recipe`, or throw if unavailable.
    func fetch(_ recipe: BuildRecipe) throws -> Data
}

public enum SourceError: Error, Equatable {
    case unavailable(String)
    case checksumMismatch(package: String, expected: String, actual: String)
}

/// Verifies fetched bytes against a recipe's `TERMUX_PKG_SHA256`.
public enum SourceVerifier {
    /// Returns the verified data. If the recipe declares no checksum, the data
    /// is accepted as-is (many platform-independent recipes omit it).
    @discardableResult
    public static func verify(_ data: Data, for recipe: BuildRecipe) throws -> Data {
        guard let expected = recipe.metadata.sha256, !expected.isEmpty else { return data }
        let actual = SHA256.hexDigest(data)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw SourceError.checksumMismatch(
                package: recipe.name, expected: expected.lowercased(), actual: actual
            )
        }
        return data
    }
}

/// A source provider backed by an in-memory map of package name to bytes.
/// Useful for tests and for fully-offline catalogs.
public final class InMemorySourceProvider: SourceProvider {
    private var sources: [String: Data] = [:]

    public init() {}

    /// Register source bytes for a package. If `matchingChecksum` is true, the
    /// recipe's declared SHA256 is (re)written to match these bytes so the
    /// verifier passes — convenient for fixtures.
    public func register(_ name: String, data: Data) {
        sources[name] = data
    }

    public func register(_ name: String, string: String) {
        sources[name] = Data(string.utf8)
    }

    public func fetch(_ recipe: BuildRecipe) throws -> Data {
        guard let data = sources[recipe.name] else {
            throw SourceError.unavailable(recipe.name)
        }
        return data
    }
}

/// A source provider that reads a recipe's `TERMUX_PKG_SRCURL` from the local
/// filesystem: a `file://` URL or an absolute path.
///
/// Real package sources live behind `https://` URLs, but fetching over the
/// network is neither offline-testable nor sandbox-friendly, so source
/// acquisition is abstracted behind ``SourceProvider``. This provider covers the
/// fully-local case (mirrors, a pre-populated cache, or bundled fixtures) and
/// exercises the entire fetch → verify → cache pipeline without a network. A
/// networked provider can be slotted in later behind the same protocol.
public final class FileSourceProvider: SourceProvider {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    public func fetch(_ recipe: BuildRecipe) throws -> Data {
        guard let url = recipe.metadata.sourceURL, !url.isEmpty,
              let path = FileSourceProvider.localPath(from: url) else {
            throw SourceError.unavailable(recipe.name)
        }
        guard let data = fm.contents(atPath: path) else {
            throw SourceError.unavailable(recipe.name)
        }
        return data
    }

    /// Convert a `file://` URL or absolute path into a local filesystem path,
    /// or nil for a relative/network URL. Handles Windows drive paths.
    static func localPath(from url: String) -> String? {
        if url.hasPrefix("file://") {
            var p = String(url.dropFirst("file://".count))
            // file:///C:/x -> /C:/x -> C:/x on Windows.
            let chars = Array(p)
            if chars.count >= 3, chars[0] == "/", chars[2] == ":" { p = String(p.dropFirst()) }
            return p
        }
        if url.hasPrefix("/") { return url }                 // absolute POSIX path
        let chars = Array(url)
        if chars.count >= 2, chars[1] == ":" { return url }  // Windows drive path
        return nil                                            // relative or network URL
    }
}

