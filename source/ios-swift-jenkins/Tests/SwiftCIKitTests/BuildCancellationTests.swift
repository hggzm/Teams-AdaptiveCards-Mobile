import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Build cancellation (Phase 8)", .serialized)
struct BuildCancellationTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-cancel-tests-\(UUID().uuidString)", isDirectory: true)
        return JobStore(root: url)
    }
    static func cleanUp(_ store: JobStore) {
        try? FileManager.default.removeItem(at: store.root)
    }
    static func waitForTerminal(
        store: JobStore, jobID: String, number: Int,
        timeout: Duration = .seconds(30)
    ) async throws -> Build {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let b = try store.loadBuild(jobID: jobID, number: number),
               b.status.isTerminal {
                return b
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.timeout
    }
    /// Wait until the build's on-disk status is `.running`. Used by
    /// cancel-while-running tests so we cancel mid-step, not before
    /// the worker has even picked the build up.
    static func waitForRunning(
        store: JobStore, jobID: String, number: Int,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let b = try store.loadBuild(jobID: jobID, number: number),
               b.status == .running {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout
    }
    enum Failure: Error { case timeout }

    // A long-running command we can reliably cancel mid-step.
    //
    // Windows: `powershell -NoProfile -Command "Start-Sleep -Seconds N"`.
    //   - `timeout /t N` errors out under redirected stdin (which
    //     `Foundation.Process` always supplies), exiting immediately.
    //   - `ping -n 60 127.0.0.1` works as a sleep but `terminate()`
    //     on the `cmd.exe /c` wrapper does NOT propagate to the
    //     `ping.exe` grandchild on Windows, so the build never gets
    //     a chance to observe cancellation.
    //   - PowerShell's `Start-Sleep` responds to its parent process
    //     being terminated cleanly.
    // POSIX: `sleep N` is portable.
    static var sleepCommand: String {
        #if os(Windows)
        return "powershell -NoProfile -Command \"Start-Sleep -Seconds 60\""
        #else
        return "sleep 60"
        #endif
    }

    @Test("cancel returns .notCancellable for an unknown build number")
    func cancelUnknown() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let executor = BuildExecutor(store: store)
        await executor.start()
        let res = await executor.cancel(jobID: "no-such-job", number: 1)
        await executor.stop()
        #expect(res == .notCancellable)
    }

    @Test("cancel removes a queued build from the queue and marks it .canceled")
    func cancelQueued() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "QueuedCancel",
            steps: [.init(name: "Slow", run: Self.sleepCommand)]
        ))
        // Don't start the executor yet — that way the build is
        // guaranteed to be in the queue when we cancel.
        let executor = BuildExecutor(store: store)
        let n1 = try await executor.enqueue(jobID: jobID)
        let n2 = try await executor.enqueue(jobID: jobID)
        #expect(await executor.queueDepth == 2)

        // Cancel the second build (still queued, never ran).
        let res = await executor.cancel(jobID: jobID, number: n2)
        #expect(res == .canceledQueued)
        #expect(await executor.queueDepth == 1)

        let canceled = try #require(try store.loadBuild(jobID: jobID, number: n2))
        #expect(canceled.status == .canceled)
        #expect(canceled.endedAt != nil)

        // The first build is still queued and untouched.
        let pending = try #require(try store.loadBuild(jobID: jobID, number: n1))
        #expect(pending.status == .queued)

        // Don't start the executor — we don't want to actually run
        // the sleep step.
    }

    @Test("cancel terminates the running step and the build ends as .canceled")
    func cancelRunning() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "RunningCancel",
            steps: [.init(name: "Slow", run: Self.sleepCommand)]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let n = try await executor.enqueue(jobID: jobID)

        // Wait until the worker has picked the build up.
        try await Self.waitForRunning(store: store, jobID: jobID, number: n)

        let res = await executor.cancel(jobID: jobID, number: n)
        #expect(res == .canceledRunning)

        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: n)
        await executor.stop()

        #expect(final.status == .canceled)
        let log = try store.readLog(jobID: jobID, number: n)
        // The build footer prints the final status.
        #expect(log.contains("finished: canceled"))
    }

    @Test("cancel on an already-terminal build returns .notCancellable (idempotent)")
    func cancelTerminal() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Quick",
            steps: [.init(name: "Echo", run: "echo done")]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let n = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(
            store: store, jobID: jobID, number: n)
        #expect(final.status == .passed)

        let res = await executor.cancel(jobID: jobID, number: n)
        await executor.stop()
        #expect(res == .notCancellable)
    }

    @Test("cancel-queued resumes WS log subscribers cleanly")
    func cancelQueuedResumesLogStream() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "QueuedWS",
            steps: [.init(name: "Slow", run: Self.sleepCommand)]
        ))
        let executor = BuildExecutor(store: store)
        let n = try await executor.enqueue(jobID: jobID)
        let stream = await executor.broadcaster.subscribe(jobID: jobID, number: n)

        let res = await executor.cancel(jobID: jobID, number: n)
        #expect(res == .canceledQueued)

        // The broadcaster should have called finish, so the stream
        // closes promptly even though we never started the worker.
        var chunks = 0
        for await _ in stream { chunks += 1 }
        // Some "canceled while queued" banner may have been appended;
        // either zero or a small number is fine.
        #expect(chunks <= 1)
    }
}
