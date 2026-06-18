import Foundation

/// Windows-friendly atomic write/read helpers.
///
/// On Windows a freshly-created file or its parent directory can be
/// transiently locked by anti-virus / search-indexer scans. The
/// kernel surfaces this as `ERROR_SHARING_VIOLATION` (Win32 32),
/// which Foundation maps to `NSCocoaErrorDomain` `513`
/// (`NSFileWriteNoPermissionError`). The window is typically 10–50 ms,
/// so a small bounded retry suffices.
///
/// These helpers are used by every persistence path in `JobStore` and
/// its extensions to keep the rest of the code free of retry loops.
enum AtomicIO {
    static func writeData(
        _ data: Data,
        to url: URL,
        attempts: Int = 8
    ) throws {
        try withRetry(attempts: attempts) {
            try data.write(to: url, options: [.atomic])
        }
    }

    static func writeString(
        _ text: String,
        to url: URL,
        encoding: String.Encoding = .utf8,
        attempts: Int = 8
    ) throws {
        try withRetry(attempts: attempts) {
            try text.write(to: url, atomically: true, encoding: encoding)
        }
    }

    static func readString(
        from url: URL,
        encoding: String.Encoding = .utf8,
        attempts: Int = 8
    ) throws -> String {
        var result: String = ""
        try withRetry(attempts: attempts) {
            result = try String(contentsOf: url, encoding: encoding)
        }
        return result
    }

    /// Run `body`, retrying on `NSFileWriteNoPermissionError` /
    /// `NSFileWriteUnknownError` (which is what `ERROR_SHARING_VIOLATION`
    /// surfaces as) with linear backoff up to `attempts` total.
    static func withRetry(
        attempts: Int,
        _ body: () throws -> Void
    ) throws {
        var attempt = 0
        while true {
            do {
                try body()
                return
            } catch let error as NSError {
                attempt += 1
                let isSharing =
                    error.domain == NSCocoaErrorDomain &&
                    (error.code == NSFileWriteNoPermissionError ||
                     error.code == NSFileWriteUnknownError ||
                     error.code == NSFileReadNoPermissionError)
                guard isSharing, attempt < attempts else { throw error }
                Thread.sleep(forTimeInterval: 0.020 * Double(attempt))
            }
        }
    }
}
