// FilesystemRetry — a small retry helper for filesystem operations
// that may transiently fail on Windows under AV-scanner contention.
//
// Mirrors the retry pattern used by `SessionStore.atomicWrite`: up to
// 5 attempts with quadratic 10ms / 40ms / 90ms / 160ms / 250ms
// backoff (Thread.sleep — cross-platform unlike usleep). Used by
// `WriteFileTool` and `EditFileTool` to absorb the brief
// "permission denied" returns we've seen during `swift test
// --parallel` on Windows.

import Foundation
import SwiftPiCore

enum FilesystemRetry {
    /// Run a throwing filesystem operation with a short, bounded
    /// retry on transient errors. Final failure is rethrown as
    /// `SwiftPiError.io` with `label` and the caught error's
    /// description.
    static func run(
        operation label: String,
        attempts: Int = 5,
        body: () throws -> Void
    ) throws {
        precondition(attempts >= 1, "attempts must be ≥1")
        for attempt in 1...attempts {
            do {
                try body()
                return
            } catch {
                if attempt == attempts {
                    throw SwiftPiError.io(
                        "\(label): \(error.localizedDescription)"
                    )
                }
                let delaySeconds = Double(attempt * attempt) * 0.010
                Thread.sleep(forTimeInterval: delaySeconds)
            }
        }
    }
}
