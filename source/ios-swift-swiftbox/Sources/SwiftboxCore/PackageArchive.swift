import Foundation

/// A self-contained, serializable package: manifest metadata plus the files it
/// installs under `$PREFIX`. This is swiftbox's on-disk package — the analogue
/// of a Termux `.deb`, but in a dependency-free text container so it can be
/// written and read identically on every platform (file contents are base64 so
/// the format is binary-safe).
public struct PackageArchive: Equatable {
    public var manifest: PackageManifest
    public var artifacts: [BuildArtifact]

    public init(manifest: PackageManifest, artifacts: [BuildArtifact]) {
        self.manifest = manifest
        self.artifacts = artifacts
    }

    public static let magic = "swiftbox-package"
    public static let formatVersion = 1

    public enum ArchiveError: Error, Equatable {
        case badMagic
        case corrupt(String)
    }

    /// Serialize to the `.sbox` container bytes.
    public func encoded() -> Data {
        var lines: [String] = []
        lines.append("\(PackageArchive.magic) \(PackageArchive.formatVersion)")
        lines.append("name: \(manifest.name)")
        lines.append("version: \(manifest.version)")
        lines.append("summary: \(manifest.summary)")
        lines.append("arch: \(manifest.arch)")
        lines.append("depends: \(manifest.dependencies.joined(separator: ","))")
        lines.append("files: \(artifacts.count)")
        for artifact in artifacts {
            let b64 = Data(artifact.contents.utf8).base64EncodedString()
            lines.append("\(artifact.path)\t\(artifact.executable ? 1 : 0)\t\(b64)")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Parse `.sbox` container bytes.
    public static func decode(_ data: Data) throws -> PackageArchive {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let header = lines.first, header.hasPrefix(magic) else {
            throw ArchiveError.badMagic
        }

        func value(_ key: String) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix("\(key): ") }) else { return nil }
            return String(line.dropFirst(key.count + 2))
        }

        guard let name = value("name"), !name.isEmpty else {
            throw ArchiveError.corrupt("missing name")
        }
        let version = SemanticVersion(parsing: value("version") ?? "0") ?? SemanticVersion(0)
        let deps = (value("depends") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let manifest = PackageManifest(
            name: name,
            version: version,
            summary: value("summary") ?? "",
            dependencies: deps,
            arch: value("arch") ?? "all"
        )

        guard let countStr = value("files"), let count = Int(countStr) else {
            throw ArchiveError.corrupt("missing file count")
        }
        // File entries are the last `count` lines.
        guard lines.count >= count else { throw ArchiveError.corrupt("truncated file list") }
        var artifacts: [BuildArtifact] = []
        for line in lines.suffix(count) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { throw ArchiveError.corrupt("bad file entry") }
            guard let raw = Data(base64Encoded: parts[2]) else {
                throw ArchiveError.corrupt("bad base64 for \(parts[0])")
            }
            artifacts.append(BuildArtifact(
                path: parts[0],
                contents: String(decoding: raw, as: UTF8.self),
                executable: parts[1] == "1"
            ))
        }
        return PackageArchive(manifest: manifest, artifacts: artifacts)
    }
}

/// A directory of `.sbox` packages on disk — the local package repository.
///
/// This is the on-disk side of the build system: `pkg build` can publish an
/// archive here, and a fresh environment can install from it without rebuilding.
/// Uses `FileManager` only, so it works on macOS, Linux, Windows and WSL, and
/// maps cleanly onto the iOS app's sandbox container later.
public final class LocalPackageStore {
    public let root: String
    private let fm: FileManager

    public init(root: String, fileManager: FileManager = .default) {
        self.root = root
        self.fm = fileManager
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    private func path(for name: String) -> String {
        (root as NSString).appendingPathComponent("\(name).sbox")
    }

    /// Write an archive into the store, keyed by package name.
    public func publish(_ archive: PackageArchive) throws {
        let url = URL(fileURLWithPath: path(for: archive.manifest.name))
        try archive.encoded().write(to: url)
    }

    public func contains(_ name: String) -> Bool {
        fm.fileExists(atPath: path(for: name))
    }

    /// Names of all packages in the store.
    public func list() -> [String] {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries.filter { $0.hasSuffix(".sbox") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    public func load(_ name: String) throws -> PackageArchive {
        guard let data = fm.contents(atPath: path(for: name)) else {
            throw SourceError.unavailable(name)
        }
        return try PackageArchive.decode(data)
    }

    /// Install a stored package into `vfs` under `prefix`. Returns staged paths.
    @discardableResult
    public func install(_ name: String, into vfs: VirtualFileSystem, prefix: String) throws -> [String] {
        let archive = try load(name)
        var staged: [String] = []
        for artifact in archive.artifacts {
            try vfs.writeFile(prefix + "/" + artifact.path, string: artifact.contents)
            staged.append(artifact.path)
        }
        let dbPath = "\(prefix)/var/lib/swiftbox/\(name).list"
        try? vfs.writeFile(dbPath, string: staged.joined(separator: "\n") + "\n")
        return staged
    }
}
