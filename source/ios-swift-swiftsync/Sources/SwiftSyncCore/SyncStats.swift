import Foundation

/// Running tally of what a sync did. Pure value type so it is trivial to assert
/// on in tests and to hand to a progress reporter.
public struct SyncStats: Sendable, Equatable {
    /// Number of regular-file entries the syncer considered.
    public var filesConsidered: Int = 0
    /// Files actually copied (destination missing / size differed / source newer).
    public var filesCopied: Int = 0
    /// Files left untouched because the destination was already current.
    public var filesUpToDate: Int = 0
    /// Directories created because they did not already exist at the destination.
    public var directoriesCreated: Int = 0
    /// Symlinks created at the destination where none existed.
    public var symlinksCreated: Int = 0
    /// Symlinks replaced at the destination because they already existed.
    public var symlinksUpdated: Int = 0
    /// Total bytes copied across all files.
    public var bytesCopied: Int64 = 0
    /// Entries removed from the destination because they had no source
    /// counterpart (only ever non-zero when `--delete` is in effect).
    public var deleted: Int = 0
    /// Number of entries that failed (one count per failed entry).
    public var errors: Int = 0

    public init() {}
}

/// A single per-entry failure. The whole run never aborts on one of these; they
/// are collected and surfaced (and optionally written to an `--err-list` file).
public struct SyncFailure: Sendable, Equatable {
    /// Relative path of the entry that failed (the same name shown in progress).
    public var entry: String
    /// Human-readable reason.
    public var message: String

    public init(entry: String, message: String) {
        self.entry = entry
        self.message = message
    }
}

/// The complete result of a sync: the tally plus every entry that errored.
public struct SyncSummary: Sendable, Equatable {
    public var stats: SyncStats
    public var failures: [SyncFailure]

    public init(stats: SyncStats = SyncStats(), failures: [SyncFailure] = []) {
        self.stats = stats
        self.failures = failures
    }

    /// True when no entry errored.
    public var succeeded: Bool { failures.isEmpty }
}
