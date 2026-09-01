import Foundation

/// Drives a one-shot recursive sync from a source directory into a destination
/// directory: it walks the tree, creates directories on the fly, applies the
/// copy decision to each file, preserves symlinks, and tallies a ``SyncSummary``.
///
/// Per the data-safety posture, a failure on one entry **never aborts the run** —
/// it is recorded in the summary and the walk continues. Nothing is deleted
/// unless `Options.delete` is set, and even then only destination entries with
/// no source counterpart (never anything under the source) are removed.
///
/// `Syncer` is an actor so that, in a later phase, a progress reporter can run
/// concurrently while this consumes entries. For now the work is synchronous
/// within the actor and an optional ``onProgress`` sink emits raw
/// ``ProgressMessage`` values for that future reporter to consume.
public actor Syncer {
    /// Tunable behavior for a sync.
    public struct Options: Sendable {
        /// Preserve POSIX permission bits on copied files. Callers make this
        /// `false` on Windows, where the bits are not meaningful.
        public var preservePermissions: Bool

        /// Glob patterns whose matching entries are skipped during the walk
        /// (and, when `delete` is on, protected from deletion). Empty by default.
        public var exclude: [String]

        /// Remove destination entries that have no source counterpart after the
        /// copy pass. Off by default — `swiftsync` never deletes unless asked.
        public var delete: Bool

        /// Follow symlinks and copy what they point to (rsync's `-L`) instead of
        /// recreating the link. Off by default — links are preserved as links.
        public var copyLinks: Bool

        public init(
            preservePermissions: Bool = true,
            exclude: [String] = [],
            delete: Bool = false,
            copyLinks: Bool = false
        ) {
            self.preservePermissions = preservePermissions
            self.exclude = exclude
            self.delete = delete
            self.copyLinks = copyLinks
        }
    }

    private let source: URL
    private let destination: URL
    private let options: Options
    private let onProgress: (@Sendable (ProgressMessage) -> Void)?

    public init(
        source: URL,
        destination: URL,
        options: Options = Options(),
        onProgress: (@Sendable (ProgressMessage) -> Void)? = nil
    ) {
        self.source = source
        self.destination = destination
        self.options = options
        self.onProgress = onProgress
    }

    /// Performs the sync and returns the tally plus any per-entry failures.
    ///
    /// - Throws: only for *fatal* conditions that prevent the run from starting
    ///   (source missing/not a directory, destination root not creatable).
    ///   Per-entry problems are captured in the returned summary, not thrown.
    public func run() throws -> SyncSummary {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw SyncError.sourceDoesNotExist(path: source.path)
        }
        guard isDir.boolValue else {
            throw SyncError.notADirectory(path: source.path)
        }
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw SyncError.createDirectoryFailed(path: destination.path, reason: String(describing: error))
        }

        let entries = try TreeWalker.walk(
            source: source, destination: destination,
            exclude: options.exclude, copyLinks: options.copyLinks)

        var summary = SyncSummary()
        onProgress?(.started(source: source.path, destination: destination.path))

        // Plan pass: when a progress reporter is attached, pre-compute how many
        // files (and bytes) will actually be copied so it has accurate percent
        // and ETA denominators. Skipped entirely when there is no reporter (the
        // scriptable, piped path) to avoid the extra stats.
        if onProgress != nil {
            var plannedFiles = 0
            var plannedBytes = 0
            for entry in entries where entry.kind == .file {
                let destinationStat = try? FSOps.stat(at: entry.destination)
                let sourceStat = FileStat(size: entry.size, modificationDate: entry.modificationDate)
                if case .copy = FSOps.decideCopy(source: sourceStat, destination: destinationStat) {
                    plannedFiles += 1
                    plannedBytes += Int(entry.size)
                }
            }
            onProgress?(.planned(numFiles: plannedFiles, totalBytes: plannedBytes))
        }

        for entry in entries {
            do {
                switch entry.kind {
                case .directory:
                    try syncDirectory(entry, fm: fm, stats: &summary.stats)
                case .file:
                    try syncFile(entry, fm: fm, stats: &summary.stats)
                case .symlink:
                    try syncSymlink(entry, fm: fm, stats: &summary.stats)
                }
            } catch {
                // Surface, never abort.
                summary.stats.errors += 1
                let message = (error as? SyncError)?.description ?? String(describing: error)
                summary.failures.append(SyncFailure(entry: entry.relativePath, message: message))
            }
        }

        // Delete pass: only when asked. Remove destination entries that have no
        // source counterpart (and are not excluded). Like the copy pass, a
        // per-entry failure here is captured and never aborts the run.
        if options.delete {
            deletePass(sourceEntries: entries, fm: fm, summary: &summary)
        }

        onProgress?(.done)
        return summary
    }

    /// Removes destination entries with no source counterpart. The set of source
    /// paths comes from the (already exclude-pruned) walk, so excluded paths are
    /// implicitly absent and therefore protected by ``DeletionPlan`` as well.
    private func deletePass(sourceEntries: [Entry], fm: FileManager, summary: inout SyncSummary) {
        let destinationEntries: [Entry]
        do {
            // Enumerate the destination tree. Excludes are applied here too so an
            // excluded path at the destination is never even considered.
            destinationEntries = try TreeWalker.walk(
                source: destination, destination: destination, exclude: options.exclude)
        } catch {
            summary.stats.errors += 1
            let message = (error as? SyncError)?.description ?? String(describing: error)
            summary.failures.append(SyncFailure(entry: ".", message: "delete walk failed: \(message)"))
            return
        }

        let sourcePaths = Set(sourceEntries.map(\.relativePath))
        let toDelete = DeletionPlan.entriesToDelete(
            sourceRelativePaths: sourcePaths,
            destinationRelativePaths: destinationEntries.map(\.relativePath),
            exclude: options.exclude
        )

        // Remove deepest paths first so a directory's children are gone (and
        // individually counted) before the directory itself is removed.
        let ordered = toDelete.sorted {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }
        for rel in ordered {
            let url = destination.appendingPathComponent(rel)
            // May already be gone if a parent was removed first; that cannot
            // happen with deepest-first ordering, but guard defensively.
            guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { continue }
            do {
                try fm.removeItem(at: url)
                summary.stats.deleted += 1
            } catch {
                summary.stats.errors += 1
                summary.failures.append(SyncFailure(entry: rel, message: "could not delete: \(error)"))
            }
        }
    }

    private func syncDirectory(_ entry: Entry, fm: FileManager, stats: inout SyncStats) throws {
        if fm.fileExists(atPath: entry.destination.path) { return }
        do {
            try fm.createDirectory(at: entry.destination, withIntermediateDirectories: true)
            stats.directoriesCreated += 1
        } catch {
            throw SyncError.createDirectoryFailed(path: entry.destination.path, reason: String(describing: error))
        }
    }

    private func syncFile(_ entry: Entry, fm: FileManager, stats: inout SyncStats) throws {
        stats.filesConsidered += 1

        let sourceStat = FileStat(size: entry.size, modificationDate: entry.modificationDate)
        let destinationStat = try FSOps.stat(at: entry.destination)

        switch FSOps.decideCopy(source: sourceStat, destination: destinationStat) {
        case .skip:
            stats.filesUpToDate += 1

        case .copy:
            onProgress?(.fileStarted(name: entry.relativePath, size: Int(entry.size)))
            let byteSink: ((Int) -> Void)? = onProgress.map { sink in
                { bytes in sink(.progressed(bytes: bytes)) }
            }
            let copied = try FSOps.copyFile(
                from: entry.source,
                to: entry.destination,
                preservePermissions: options.preservePermissions,
                onBytesCopied: byteSink
            )
            stats.filesCopied += 1
            stats.bytesCopied += copied
            onProgress?(.fileDone)
        }
    }

    private func syncSymlink(_ entry: Entry, fm: FileManager, stats: inout SyncStats) throws {
        let target: String
        do {
            target = try fm.destinationOfSymbolicLink(atPath: entry.source.path)
        } catch {
            throw SyncError.readFailed(path: entry.source.path, reason: String(describing: error))
        }

        // lstat-style existence check so an existing (even broken) symlink at the
        // destination is detected and replaced rather than duplicated.
        let destinationExists = (try? fm.attributesOfItem(atPath: entry.destination.path)) != nil
        if destinationExists {
            try? fm.removeItem(at: entry.destination)
        }
        do {
            try fm.createSymbolicLink(atPath: entry.destination.path, withDestinationPath: target)
        } catch {
            throw SyncError.writeFailed(path: entry.destination.path, reason: String(describing: error))
        }
        if destinationExists {
            stats.symlinksUpdated += 1
        } else {
            stats.symlinksCreated += 1
        }
    }
}
