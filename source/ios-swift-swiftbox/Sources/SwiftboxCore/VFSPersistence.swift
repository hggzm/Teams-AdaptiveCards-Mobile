import Foundation

/// Mirrors a subtree of a ``VirtualFileSystem`` onto a real host directory and
/// restores it back.
///
/// On stock iOS an app cannot mount a second root filesystem, but it *can* read
/// and write its own sandbox container. ``VFSPersistence`` is how the virtual
/// `$PREFIX` userland survives across launches: snapshot the in-memory tree onto
/// the container on changes, and rehydrate it on the next start. It uses
/// `FileManager` only, so it behaves identically on macOS, Linux, Windows and
/// WSL, and maps cleanly onto the iOS sandbox later.
///
/// A virtual path like `/data/swiftbox/usr/etc/motd` is stored relative to a
/// chosen virtual `root`, so persisting `root = "/data/swiftbox"` to host
/// `container/` writes `container/usr/etc/motd`.
public enum VFSPersistence {
    public enum PersistenceError: Error, Equatable {
        case rootNotADirectory(String)
    }

    /// Write everything under the virtual `root` into the host `container`
    /// directory. Returns the number of files written.
    @discardableResult
    public static func save(
        _ vfs: VirtualFileSystem,
        root: String,
        to container: String,
        fileManager fm: FileManager = .default
    ) throws -> Int {
        guard vfs.isDirectory(root) else { throw PersistenceError.rootNotADirectory(root) }
        try fm.createDirectory(atPath: container, withIntermediateDirectories: true)

        var fileCount = 0
        for entry in try vfs.walk(root) {
            let relative = relativePath(of: entry.path, under: root)
            guard !relative.isEmpty else { continue }
            let hostPath = (container as NSString).appendingPathComponent(relative)
            if entry.isDirectory {
                try fm.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
            } else {
                let parent = (hostPath as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                let data = (try? vfs.readFile(entry.path)) ?? Data()
                try data.write(to: URL(fileURLWithPath: hostPath))
                fileCount += 1
            }
        }
        return fileCount
    }

    /// Load a host `container` directory back into the virtual filesystem under
    /// `root`, recreating directories and files. Returns the number of files
    /// restored.
    @discardableResult
    public static func load(
        _ vfs: VirtualFileSystem,
        root: String,
        from container: String,
        fileManager fm: FileManager = .default
    ) throws -> Int {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: container, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        _ = try? vfs.makeDirectory(root)

        var fileCount = 0
        let containerURL = URL(fileURLWithPath: container)
        guard let enumerator = fm.enumerator(atPath: container) else { return 0 }
        for case let rel as String in enumerator {
            let hostPath = containerURL.appendingPathComponent(rel).path
            let virtualPath = joinVirtual(root, rel)
            var entryIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: hostPath, isDirectory: &entryIsDir)
            if entryIsDir.boolValue {
                try vfs.makeDirectory(virtualPath)
            } else {
                let data = fm.contents(atPath: hostPath) ?? Data()
                try vfs.writeFile(virtualPath, data: data)
                fileCount += 1
            }
        }
        return fileCount
    }

    // MARK: Helpers

    static func relativePath(of path: String, under root: String) -> String {
        let normalizedRoot = root == "/" ? "" : root
        guard path.hasPrefix(normalizedRoot) else { return "" }
        var rel = String(path.dropFirst(normalizedRoot.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    static func joinVirtual(_ root: String, _ relative: String) -> String {
        // Host enumerators may use "\" on Windows; normalize to "/".
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        if root == "/" { return "/" + normalized }
        return root + "/" + normalized
    }
}
