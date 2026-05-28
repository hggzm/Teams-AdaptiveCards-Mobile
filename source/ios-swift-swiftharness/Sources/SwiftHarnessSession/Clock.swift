// SwiftHarnessSession — Clock
//
// Injectable monotonic-ish clock so SessionStore writes deterministic
// timestamps in tests. Production uses `SystemClock`; tests use a
// `FixedClock` or `AdvancingClock` to assert on exact `created_at_ms`
// and `updated_at_ms` values.

import Foundation

/// Source of millisecond-since-epoch wall-clock timestamps.
public protocol HarnessClock: Sendable {
    /// Return the current time in milliseconds since the Unix epoch.
    func nowMs() -> Int64
}

/// `HarnessClock` backed by the host's real clock.
public struct SystemClock: HarnessClock {
    public init() {}

    public func nowMs() -> Int64 {
        // `Date().timeIntervalSince1970` is seconds (Double) since the
        // Unix epoch. Multiply by 1000 and floor to milliseconds.
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
