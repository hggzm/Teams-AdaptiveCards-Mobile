/// Decides which destination entries should be removed when `--delete` is in
/// effect: those present at the destination but **absent from the source**.
/// Pure and total — no I/O — because deletion is the single most dangerous
/// operation in the tool and its decision must be exhaustively unit-tested.
///
/// Two safety rules are baked in:
/// - An entry that exists in the source is never deleted.
/// - An entry that matches the active exclude patterns is never deleted, so
///   `--exclude`d paths at the destination are *protected* rather than purged.
public enum DeletionPlan {
    /// Returns the destination-relative paths to delete, given the set of
    /// relative paths that exist in the source, every relative path found at the
    /// destination, and the active exclude patterns.
    ///
    /// The result preserves the order of `destinationRelativePaths`; the caller
    /// is responsible for removing deepest paths first so a directory is empty
    /// (and individually counted) before it is removed.
    public static func entriesToDelete(
        sourceRelativePaths: Set<String>,
        destinationRelativePaths: [String],
        exclude: [String] = []
    ) -> [String] {
        destinationRelativePaths.filter { rel in
            !sourceRelativePaths.contains(rel)
                && !ExcludeFilter.isExcluded(relativePath: rel, patterns: exclude)
        }
    }
}
