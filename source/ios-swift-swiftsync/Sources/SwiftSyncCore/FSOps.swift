import Foundation

/// A minimal stat of a filesystem entry: just the two facts the copy decision
/// depends on. Pure value type so the decision function can be tested without
/// touching the filesystem.
public struct FileStat: Equatable, Sendable {
    /// Size in bytes.
    public var size: Int64
    /// Modification time, if the platform/filesystem reports one.
    public var modificationDate: Date?

    public init(size: Int64, modificationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// Why a file was selected for copying.
public enum CopyReason: Equatable, Sendable {
    case destinationMissing
    case sizeDiffers
    case sourceNewer
}

/// The result of the copy decision: either copy (with the reason) or skip.
public enum CopyDecision: Equatable, Sendable {
    case copy(CopyReason)
    case skip
}

/// Filesystem operations: the copy decision plus the byte-copy and
/// metadata-preservation primitives that act on it.
///
/// `FSOps` owns the platform-touching surface of the tool, but keeps that
/// surface tiny and routed through `FileManager` so it builds unchanged on
/// macOS, Linux, and Windows.
public enum FSOps {
    /// **The single most important function in the tool.** Decides whether
    /// `source` must be copied over `destination`. Pure and total — it performs
    /// no I/O — so it can be exhaustively unit-tested. A bug here would mean
    /// silent data divergence, so the decision matrix is tested case by case.
    ///
    /// Rules, evaluated in order (mirroring rusync's semantics):
    /// 1. destination missing             → `.copy(.destinationMissing)`
    /// 2. sizes differ                    → `.copy(.sizeDiffers)`
    /// 3. source strictly newer than dest → `.copy(.sourceNewer)`
    /// 4. otherwise                       → `.skip`
    ///
    /// The modification-time comparison requires both timestamps to be present
    /// and uses strict greater-than. Equal timestamps, or an unknown timestamp
    /// on either side once sizes already match, therefore resolve to `.skip` —
    /// the tool never claims "newer" unless it can prove it.
    public static func decideCopy(source: FileStat, destination: FileStat?) -> CopyDecision {
        guard let destination else {
            return .copy(.destinationMissing)
        }
        if source.size != destination.size {
            return .copy(.sizeDiffers)
        }
        if let s = source.modificationDate, let d = destination.modificationDate, s > d {
            return .copy(.sourceNewer)
        }
        return .skip
    }

    /// Reads size + modification date for `url`. Returns `nil` when the path does
    /// not exist (the common "destination missing" case); throws
    /// ``SyncError/metadataFailed(path:reason:)`` on any other failure.
    public static func stat(at url: URL) throws -> FileStat? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mdate = attrs[.modificationDate] as? Date
            return FileStat(size: size, modificationDate: mdate)
        } catch {
            throw SyncError.metadataFailed(path: url.path, reason: String(describing: error))
        }
    }

    private static let copyChunkSize = 256 * 1024

    /// Copies the *bytes* of `source` to `destination` without ever truncating
    /// the destination in place: the data is streamed to a temporary file in the
    /// destination's own directory, flushed to disk, then moved over the target.
    ///
    /// On Windows we deliberately avoid `FileManager.replaceItemAt` (not
    /// implemented there — it traps), so any existing destination is removed
    /// immediately before the same-directory rename. That replacement window is
    /// tiny but not perfectly atomic; it is documented rather than hidden.
    ///
    /// - Parameter onBytesCopied: called with the size of each chunk as it is
    ///   written, so a progress reporter can follow along off the decision path.
    /// - Returns: the total number of bytes copied.
    @discardableResult
    public static func copyFileContents(
        from source: URL,
        to destination: URL,
        onBytesCopied: ((Int) -> Void)? = nil
    ) throws -> Int64 {
        let fm = FileManager.default
        let destDir = destination.deletingLastPathComponent()
        let tmp = destDir.appendingPathComponent(
            ".swiftsync.tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        )

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw SyncError.readFailed(path: source.path, reason: String(describing: error))
        }

        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            try? input.close()
            throw SyncError.writeFailed(path: tmp.path, reason: "could not create temporary file")
        }

        var total: Int64 = 0
        do {
            let output = try FileHandle(forWritingTo: tmp)
            do {
                while let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    total += Int64(chunk.count)
                    onBytesCopied?(chunk.count)
                }
                // Best-effort flush to stable storage before the rename. Some
                // platforms may not honor this; the temp+rename still protects
                // the destination from a half-written state.
                try? output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            try input.close()
        } catch {
            try? input.close()
            try? fm.removeItem(at: tmp)
            throw SyncError.copyFailed(entry: source.lastPathComponent, reason: String(describing: error))
        }

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            try? fm.removeItem(at: tmp)
            throw SyncError.writeFailed(path: destination.path, reason: String(describing: error))
        }
        return total
    }

    /// Copies `source`'s modification date onto `destination`.
    ///
    /// Precision is whatever `FileManager` reports on the platform: at least
    /// second-level everywhere, sub-second where the filesystem supports it. We
    /// stay on `FileManager` rather than dropping to `utimensat`/`SetFileTime`
    /// because the decision function only relies on strict ordering, for which
    /// this precision is sufficient.
    public static func preserveModificationDate(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: source.path)
        } catch {
            throw SyncError.metadataFailed(path: source.path, reason: String(describing: error))
        }
        guard let mdate = attrs[.modificationDate] as? Date else { return }
        do {
            try fm.setAttributes([.modificationDate: mdate], ofItemAtPath: destination.path)
        } catch {
            throw SyncError.writeFailed(
                path: destination.path,
                reason: "could not set modification date: \(error)"
            )
        }
    }

    /// Copies `source`'s POSIX permission bits onto `destination`.
    ///
    /// This is largely a no-op on Windows, where POSIX modes are not
    /// meaningfully represented; callers make `--no-perms` the implicit default
    /// there. On macOS and Linux it preserves the mode bits.
    public static func preservePermissions(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: source.path)
        } catch {
            throw SyncError.metadataFailed(path: source.path, reason: String(describing: error))
        }
        guard let perms = attrs[.posixPermissions] as? NSNumber else { return }
        do {
            try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: destination.path)
        } catch {
            throw SyncError.writeFailed(
                path: destination.path,
                reason: "could not set permissions: \(error)"
            )
        }
    }

    /// Full file copy: atomic byte copy, then modification-time preservation,
    /// then optional permission preservation. The order matters — metadata is
    /// applied to the destination only after its bytes are safely in place.
    ///
    /// - Returns: the number of bytes copied.
    @discardableResult
    public static func copyFile(
        from source: URL,
        to destination: URL,
        preservePermissions preservePerms: Bool = true,
        onBytesCopied: ((Int) -> Void)? = nil
    ) throws -> Int64 {
        let copied = try copyFileContents(from: source, to: destination, onBytesCopied: onBytesCopied)
        try preserveModificationDate(from: source, to: destination)
        if preservePerms {
            try preservePermissions(from: source, to: destination)
        }
        return copied
    }
}
