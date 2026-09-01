import Foundation

/// Walks a source directory tree and produces an ``Entry`` for every item under
/// it (files, directories, and symlinks), pairing each with the destination
/// path it should occupy.
///
/// The walk is **pre-order**: a directory entry always appears before the
/// entries it contains, so a consumer can create each directory before copying
/// anything into it. By default symlinks are reported as leaf
/// ``EntryKind/symlink`` entries and are never followed, so the tree cannot
/// loop. When `copyLinks` is set (rsync's `-L`/`--copy-links`), a symlink is
/// instead *followed* and reported as the file or directory it points to; a
/// cycle guard prevents runaway recursion, and dangling links are skipped.
/// Children are visited in sorted name order for deterministic output
/// (important for the fixture tests).
public enum TreeWalker {
    /// Produces entries for everything under `source`, with destination paths
    /// rooted at `destination`. The roots themselves are not emitted — only
    /// their contents, mirroring `swiftsync SRC DEST` placing SRC's contents
    /// directly under DEST.
    ///
    /// Entries matching any `exclude` glob are pruned: an excluded file or
    /// symlink is skipped, and an excluded directory is skipped *along with its
    /// entire subtree* (we never descend into it).
    ///
    /// When `copyLinks` is true, symlinks are resolved to their referent: a link
    /// to a file is emitted as that file (with the target's size/mtime and the
    /// target as the copy source), and a link to a directory is descended into.
    /// Dangling links are skipped.
    ///
    /// - Throws: ``SyncError/sourceDoesNotExist(path:)`` or
    ///   ``SyncError/notADirectory(path:)`` if the source root is unusable.
    public static func walk(
        source: URL,
        destination: URL,
        exclude: [String] = [],
        copyLinks: Bool = false
    ) throws -> [Entry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw SyncError.sourceDoesNotExist(path: source.path)
        }
        guard isDir.boolValue else {
            throw SyncError.notADirectory(path: source.path)
        }

        var entries: [Entry] = []
        // Canonical directory paths already descended into, so a followed
        // symlink that points back to an ancestor cannot loop forever. Only
        // consulted when `copyLinks` is on (a plain tree has no cycles).
        var visited: Set<String> = copyLinks ? [source.standardizedFileURL.path] : []
        try walkDirectory(
            relativePrefix: "",
            source: source,
            destination: destination,
            exclude: exclude,
            copyLinks: copyLinks,
            visited: &visited,
            into: &entries,
            fm: fm
        )
        return entries
    }

    private static func walkDirectory(
        relativePrefix: String,
        source: URL,
        destination: URL,
        exclude: [String],
        copyLinks: Bool,
        visited: inout Set<String>,
        into entries: inout [Entry],
        fm: FileManager
    ) throws {
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: source.path).sorted()
        } catch {
            throw SyncError.readFailed(path: source.path, reason: String(describing: error))
        }

        for name in names {
            let childSource = source.appendingPathComponent(name)
            let childDestination = destination.appendingPathComponent(name)
            let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"

            // Prune excluded entries (and, for directories, their whole subtree).
            if ExcludeFilter.isExcluded(relativePath: relativePath, patterns: exclude) {
                continue
            }

            // `attributesOfItem` uses lstat semantics on every platform, so it
            // does not follow symlinks — a symlink reports as a symlink.
            let attrs = try? fm.attributesOfItem(atPath: childSource.path)
            let type = attrs?[.type] as? FileAttributeType
            let mdate = attrs?[.modificationDate] as? Date

            // --copy-links: resolve a symlink to its referent and treat it as
            // that file/directory instead of recreating the link.
            if copyLinks, type == .some(.typeSymbolicLink) {
                guard
                    let targetURL = resolvedTarget(of: childSource, fm: fm),
                    let targetAttrs = try? fm.attributesOfItem(atPath: targetURL.path)
                else {
                    // Dangling or unresolvable link: skip (matches rsync's
                    // warn-and-skip for a symlink with no referent under -L).
                    continue
                }
                let targetType = targetAttrs[.type] as? FileAttributeType
                let targetMdate = targetAttrs[.modificationDate] as? Date

                if targetType == .some(.typeDirectory) {
                    entries.append(Entry(
                        relativePath: relativePath,
                        source: targetURL,
                        destination: childDestination,
                        kind: .directory,
                        size: 0,
                        modificationDate: targetMdate
                    ))
                    let canon = targetURL.standardizedFileURL.path
                    if !visited.contains(canon) {
                        visited.insert(canon)
                        try walkDirectory(
                            relativePrefix: relativePath,
                            source: targetURL,
                            destination: childDestination,
                            exclude: exclude,
                            copyLinks: copyLinks,
                            visited: &visited,
                            into: &entries,
                            fm: fm
                        )
                    }
                } else {
                    let size = (targetAttrs[.size] as? NSNumber)?.int64Value ?? 0
                    entries.append(Entry(
                        relativePath: relativePath,
                        source: targetURL,
                        destination: childDestination,
                        kind: .file,
                        size: size,
                        modificationDate: targetMdate
                    ))
                }
                continue
            }

            switch type {
            case .some(.typeDirectory):
                entries.append(Entry(
                    relativePath: relativePath,
                    source: childSource,
                    destination: childDestination,
                    kind: .directory,
                    size: 0,
                    modificationDate: mdate
                ))
                try walkDirectory(
                    relativePrefix: relativePath,
                    source: childSource,
                    destination: childDestination,
                    exclude: exclude,
                    copyLinks: copyLinks,
                    visited: &visited,
                    into: &entries,
                    fm: fm
                )

            case .some(.typeSymbolicLink):
                entries.append(Entry(
                    relativePath: relativePath,
                    source: childSource,
                    destination: childDestination,
                    kind: .symlink,
                    size: 0,
                    modificationDate: mdate
                ))

            default:
                // Regular file, or anything we could not stat (emitted as a file
                // so the copy attempt surfaces the real error instead of being
                // silently dropped).
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                entries.append(Entry(
                    relativePath: relativePath,
                    source: childSource,
                    destination: childDestination,
                    kind: .file,
                    size: size,
                    modificationDate: mdate
                ))
            }
        }
    }

    /// Resolves one level of symbolic link to an absolute URL. Relative targets
    /// are resolved against the link's own directory. Returns `nil` when the
    /// path is not a symlink we can read; the resulting URL may still point at a
    /// non-existent file (a dangling link), which the caller detects by failing
    /// to stat it.
    private static func resolvedTarget(of link: URL, fm: FileManager) -> URL? {
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        if (dest as NSString).isAbsolutePath {
            return URL(fileURLWithPath: dest)
        }
        return link.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
    }
}
