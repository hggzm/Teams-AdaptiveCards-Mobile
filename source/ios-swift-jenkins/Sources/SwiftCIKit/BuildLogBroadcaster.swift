import Foundation

/// Per-build live-log pub/sub used by the executor + WebSocket route.
///
/// Subscribers receive an `AsyncStream<String>` of log chunks for one
/// build (`(jobID, number)`). The executor publishes a chunk after
/// every `appendLog(...)` call and calls `finish(...)` when the build
/// reaches a terminal state. After `finish(...)`, every existing
/// subscriber's stream is closed; subscribing to an already-finished
/// build yields a stream that is closed immediately.
///
/// Implementation note: each subscriber gets its own
/// `AsyncStream.Continuation`. We don't replay history on subscribe —
/// new subscribers see only chunks emitted after their subscription.
/// The HTTP route compensates by serving the persisted `log.txt` for
/// historical context before opening the WebSocket.
public actor BuildLogBroadcaster {
    private struct Key: Hashable, Sendable {
        let jobID: String
        let number: Int
    }

    /// Active subscriber continuations keyed by build.
    /// Builds that have already finished are NOT kept here; subscribing
    /// to a finished build returns an immediately-closed stream.
    private var subscribers: [Key: [UUID: AsyncStream<String>.Continuation]] = [:]
    /// Builds we have already seen finish so that late subscribers get
    /// a closed stream rather than blocking forever.
    private var finished: Set<Key> = []

    public init() {}

    // ──────────────────────────────────────────────────────────────────
    // Publisher side
    // ──────────────────────────────────────────────────────────────────

    /// Publish a log chunk for a build. No-op if no one is subscribed.
    public func publish(jobID: String, number: Int, _ chunk: String) {
        guard !chunk.isEmpty else { return }
        let key = Key(jobID: jobID, number: number)
        guard let continuations = subscribers[key] else { return }
        for (_, cont) in continuations {
            cont.yield(chunk)
        }
    }

    /// Mark a build as finished; closes every active subscriber stream
    /// and records the key so future subscribers see a closed stream
    /// immediately.
    public func finish(jobID: String, number: Int) {
        let key = Key(jobID: jobID, number: number)
        finished.insert(key)
        if let continuations = subscribers.removeValue(forKey: key) {
            for (_, cont) in continuations {
                cont.finish()
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Subscriber side
    // ──────────────────────────────────────────────────────────────────

    /// Subscribe to live log chunks for a build.
    ///
    /// The returned stream is closed when the build finishes. If the
    /// build has *already* finished, the stream is closed immediately
    /// (the consumer gets exactly zero chunks). The unique `UUID` lets
    /// the broadcaster remove the per-subscriber continuation on
    /// stream termination.
    public func subscribe(jobID: String, number: Int) -> AsyncStream<String> {
        let key = Key(jobID: jobID, number: number)
        let id = UUID()

        // Late subscribers to an already-finished build get a closed
        // stream. We use unfolding `nil` to avoid any continuation
        // bookkeeping for this case.
        if finished.contains(key) {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            // Record the continuation under (key, id). On stream
            // termination (consumer task cancelled, or finish()), drop
            // it. The broadcaster itself doesn't see cancellation, so
            // the onTermination hook is mandatory.
            self.attach(key: key, id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.detach(key: key, id: id) }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Private bookkeeping
    // ──────────────────────────────────────────────────────────────────

    private func attach(key: Key, id: UUID, continuation: AsyncStream<String>.Continuation) {
        // If the build finished between the `finished.contains` check
        // and now, immediately close.
        if finished.contains(key) {
            continuation.finish()
            return
        }
        var bucket = subscribers[key] ?? [:]
        bucket[id] = continuation
        subscribers[key] = bucket
    }

    private func detach(key: Key, id: UUID) {
        guard var bucket = subscribers[key] else { return }
        bucket.removeValue(forKey: id)
        if bucket.isEmpty {
            subscribers.removeValue(forKey: key)
        } else {
            subscribers[key] = bucket
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Test/diagnostic helpers
    // ──────────────────────────────────────────────────────────────────

    public func subscriberCount(jobID: String, number: Int) -> Int {
        subscribers[Key(jobID: jobID, number: number)]?.count ?? 0
    }

    public func isFinished(jobID: String, number: Int) -> Bool {
        finished.contains(Key(jobID: jobID, number: number))
    }
}
