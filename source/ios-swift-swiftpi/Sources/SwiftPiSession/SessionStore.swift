// SessionStore — actor that owns a single JSONL v3 session file on disk.
//
// All filesystem mutation goes through here so we can:
//   - Serialize concurrent appends from the agent loop.
//   - Apply the same write-to-temp + move pattern on every save,
//     working around the Windows swift-corelibs-foundation gap where
//     `FileManager.replaceItemAt` is not implemented (see user memory
//     /memories/swift-foundation-filemanager-windows.md).
//
// The store does NOT cache the entry list in memory; callers that want
// the current entries call `read()` to get a fresh snapshot. For
// append-heavy agent loops this is fine because each append is O(1)
// disk I/O and the cost of re-reading on read() is paid only at
// turn boundaries.

import Foundation
import SwiftPiCore

public actor SessionStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: - Read

    /// Read the current session file, returning every entry plus any
    /// per-line decode errors. Returns an empty result for an absent
    /// file (the conventional "fresh session" state).
    public func read() throws -> JSONLReadResult {
        try JSONLReader.decode(contentsOf: url)
    }

    /// Convenience: read entries only, throwing on the first per-line
    /// decode error if any. Useful in tests and when the caller wants
    /// strict semantics.
    public func readStrict() throws -> [SessionEntry] {
        let result = try JSONLReader.decode(contentsOf: url)
        if let first = result.errors.first {
            throw SwiftPiError.malformedJSON(first.description)
        }
        return result.entries
    }

    // MARK: - Write

    /// Append a single entry, durably, by writing the full new
    /// transcript to a sibling temp file and then moving it into place.
    /// We deliberately avoid `appendingData(...)` because a torn write
    /// in the middle of a line would leave an invalid JSONL file; the
    /// temp-then-move pattern leaves the existing file fully intact if
    /// the host crashes mid-write.
    public func append(_ entry: SessionEntry) throws {
        var existing = try Data(contentsOfIfExists: url)
        let line = try JSONLWriter.encodeLine(entry)
        existing.append(line)
        try atomicWrite(existing, to: url)
    }

    /// Overwrite the session file with the given list of entries.
    /// Used by session-init paths and by tests that want a specific
    /// starting state.
    public func write(_ entries: [SessionEntry]) throws {
        let bytes = try JSONLWriter.encode(entries)
        try atomicWrite(bytes, to: url)
    }

    // MARK: - Path helpers

    public func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Internal

    /// Write `data` to `target` atomically: write to a temp sibling
    /// file, then move it over the existing file. On Windows we cannot
    /// use `FileManager.replaceItemAt` (not implemented), so we do
    /// remove-then-move; that brief window is acceptable for the
    /// single-process agent CLI we are building, and matches the
    /// recipe in /memories/swift-foundation-filemanager-windows.md.
    private func atomicWrite(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SwiftPiError.io(
                "could not create session directory at \(directory.path): \(error.localizedDescription)"
            )
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = directory.appendingPathComponent(
            "\(target.lastPathComponent).tmp-\(pid)-\(UUID().uuidString)"
        )
        // Tmp write under contention (e.g. Windows AV scanning) can
        // briefly return "permission denied". Retry a handful of
        // times with a short backoff before giving up.
        try Self.withTransientRetry(operation: "tmp write at \(tmp.path)") {
            try data.write(to: tmp, options: .atomic)
        }
        // Replace existing file: remove if present, then move.
        if fm.fileExists(atPath: target.path) {
            do {
                try Self.withTransientRetry(operation: "remove existing session at \(target.path)") {
                    try fm.removeItem(at: target)
                }
            } catch {
                // Best-effort cleanup of the tmp file before we throw.
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
        do {
            try Self.withTransientRetry(operation: "move into place at \(target.path)") {
                try fm.moveItem(at: tmp, to: target)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Run a throwing filesystem operation with a short, bounded
    /// retry on transient errors (Windows AV holds, brief sharing
    /// violations, NFS retries). Up to 5 attempts with quadratic
    /// backoff (10ms / 40ms / 90ms / 160ms / 250ms). Any non-IO
    /// error or final exhausted retry is rethrown as
    /// `SwiftPiError.io`.
    private static func withTransientRetry(
        operation label: String,
        body: () throws -> Void
    ) throws {
        let attempts = 5
        for attempt in 1...attempts {
            do {
                try body()
                return
            } catch {
                if attempt == attempts {
                    throw SwiftPiError.io("\(label): \(error.localizedDescription)")
                }
                // Sleep on a real OS thread; we cannot await inside
                // a non-async filesystem helper. The total worst-case
                // wall time across all retries is well under a
                // second. Thread.sleep is cross-platform unlike usleep.
                let delaySeconds = Double(attempt * attempt) * 0.010
                Thread.sleep(forTimeInterval: delaySeconds)
            }
        }
    }
}

// MARK: - Data helpers

private extension Data {
    /// Read `Data` from `url`, or return empty when the file is absent.
    init(contentsOfIfExists url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            self = Data()
            return
        }
        do {
            self = try Data(contentsOf: url)
        } catch {
            throw SwiftPiError.io(
                "read failed at \(url.path): \(error.localizedDescription)"
            )
        }
    }
}
