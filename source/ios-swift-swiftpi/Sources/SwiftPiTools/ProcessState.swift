// ProcessState — one-shot completion latch backed by `NSLock`.
//
// Used by `BashTool` to arbitrate between a `terminationHandler`
// callback and a parallel timeout `Task`. Whichever code path calls
// `markCompleted()` first wins and gets to resume the suspending
// continuation; the loser sees `false` and silently drops its result.
//
// An earlier draft used an actor latch; that required every caller
// (including the Foundation termination-handler thread) to hop to
// the actor executor via `await`, which proved unreliable on Windows
// — handlers were never scheduled, leaving the continuation
// un-resumed indefinitely. An `NSLock` keeps `markCompleted()`
// entirely synchronous and free of executor quirks, while still
// being safe to invoke from any thread.

import Foundation

public final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    public init() {}

    /// Attempt to claim the one-shot. Returns `true` exactly once per
    /// instance; the caller that gets `true` is responsible for
    /// resuming any pending continuation. Every other caller must
    /// silently drop its result. Safe to call from any thread.
    public func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }
}
