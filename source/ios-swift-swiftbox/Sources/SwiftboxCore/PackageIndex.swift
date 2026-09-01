import Foundation

/// One entry in a package index: a package's name, version, and the SHA-256 of
/// its `.sbox` archive bytes.
public struct PackageIndexEntry: Equatable {
    public var name: String
    public var version: SemanticVersion
    public var sha256: String

    public init(name: String, version: SemanticVersion, sha256: String) {
        self.name = name
        self.version = version
        self.sha256 = sha256
    }
}

/// A signed manifest of the packages available in a ``LocalPackageStore``.
///
/// `pkg update` fetches an index; `pkg upgrade` compares installed versions
/// against it. The index carries a keyed signature so a client can detect
/// tampering before trusting it. The signature is a dependency-free HMAC-SHA256
/// over the canonical entry list — no Apple-only crypto, so it verifies the same
/// way on every platform and inside the iOS sandbox.
public struct PackageIndex: Equatable {
    public var entries: [PackageIndexEntry]
    public var signature: String

    public static let magic = "swiftbox-index"
    public static let formatVersion = 1

    public init(entries: [PackageIndexEntry], signature: String = "") {
        self.entries = entries
        self.signature = signature
    }

    public func entry(for name: String) -> PackageIndexEntry? {
        entries.first { $0.name == name }
    }

    /// Canonical text over which the signature is computed (sorted, stable).
    func canonicalBody() -> String {
        entries
            .sorted { $0.name < $1.name }
            .map { "\($0.name)\t\($0.version)\t\($0.sha256)" }
            .joined(separator: "\n")
    }

    /// Return a copy signed with `key`.
    public func signed(withKey key: String) -> PackageIndex {
        PackageIndex(entries: entries, signature: HMAC.sha256Hex(key: key, message: canonicalBody()))
    }

    /// Verify the signature against `key`.
    public func isValid(key: String) -> Bool {
        !signature.isEmpty && HMAC.sha256Hex(key: key, message: canonicalBody()) == signature
    }

    /// Serialize to index file bytes.
    public func encoded() -> Data {
        var lines: [String] = ["\(PackageIndex.magic) \(PackageIndex.formatVersion)"]
        lines.append("signature: \(signature)")
        lines.append("entries: \(entries.count)")
        for e in entries.sorted(by: { $0.name < $1.name }) {
            lines.append("\(e.name)\t\(e.version)\t\(e.sha256)")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public enum IndexError: Error, Equatable {
        case badMagic
        case corrupt(String)
    }

    /// Parse index file bytes.
    public static func decode(_ data: Data) throws -> PackageIndex {
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let header = lines.first, header.hasPrefix(magic) else { throw IndexError.badMagic }
        func value(_ key: String) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix("\(key): ") }) else { return nil }
            return String(line.dropFirst(key.count + 2))
        }
        let signature = value("signature") ?? ""
        guard let countStr = value("entries"), let count = Int(countStr) else {
            throw IndexError.corrupt("missing entry count")
        }
        guard lines.count >= count else { throw IndexError.corrupt("truncated entries") }
        var entries: [PackageIndexEntry] = []
        for line in lines.suffix(count) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { throw IndexError.corrupt("bad entry") }
            let version = SemanticVersion(parsing: parts[1]) ?? SemanticVersion(0)
            entries.append(PackageIndexEntry(name: parts[0], version: version, sha256: parts[2]))
        }
        return PackageIndex(entries: entries, signature: signature)
    }

    /// Build a signed index by hashing every `.sbox` archive in `store`.
    public static func build(from store: LocalPackageStore, key: String) -> PackageIndex {
        var entries: [PackageIndexEntry] = []
        for name in store.list() {
            guard let archive = try? store.load(name) else { continue }
            let sha = SHA256.hexDigest(archive.encoded())
            entries.append(PackageIndexEntry(
                name: archive.manifest.name, version: archive.manifest.version, sha256: sha
            ))
        }
        return PackageIndex(entries: entries).signed(withKey: key)
    }
}

/// A minimal, dependency-free HMAC-SHA256 built on the in-house ``SHA256``.
public enum HMAC {
    public static func sha256Hex(key: String, message: String) -> String {
        let blockSize = 64
        var keyBytes = Array(key.utf8)
        if keyBytes.count > blockSize { keyBytes = SHA256.digest(keyBytes) }
        if keyBytes.count < blockSize { keyBytes += [UInt8](repeating: 0, count: blockSize - keyBytes.count) }
        let oKeyPad = keyBytes.map { $0 ^ 0x5c }
        let iKeyPad = keyBytes.map { $0 ^ 0x36 }
        let inner = SHA256.digest(iKeyPad + Array(message.utf8))
        let digest = SHA256.digest(oKeyPad + inner)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
