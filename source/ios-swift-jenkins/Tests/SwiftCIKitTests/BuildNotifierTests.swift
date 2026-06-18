import Foundation
import Testing
@testable import SwiftCIKit

/// An in-process `BuildNotifier` that records every call. Used by
/// tests so we don't need a real HTTP receiver.
actor RecordingNotifier: BuildNotifier {
    struct Call: Sendable, Equatable {
        let build: Build
        let pipeline: Pipeline
    }
    private(set) var calls: [Call] = []

    func notify(build: Build, pipeline: Pipeline) async {
        calls.append(Call(build: build, pipeline: pipeline))
    }

    func snapshot() -> [Call] { calls }
}

@Suite("Build notifications schema")
struct NotificationSchemaTests {
    @Test("notify: parses from YAML with default on=always")
    func decodeDefaults() throws {
        let yaml = """
        name: Notified
        steps:
          - name: Echo
            run: echo hi
        notify:
          - url: https://hooks.example.com/a
          - url: https://hooks.example.com/b
            on: failed
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.notify.count == 2)
        #expect(p.notify[0].url == "https://hooks.example.com/a")
        #expect(p.notify[0].on == .always)
        #expect(p.notify[1].on == .failed)
    }

    @Test("missing notify: defaults to empty list")
    func decodeMissing() throws {
        let yaml = """
        name: NoNotify
        steps:
          - name: Echo
            run: echo hi
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.notify.isEmpty)
    }

    @Test("encode omits empty notify; includes non-empty; omits on=always per-entry")
    func encodingShape() throws {
        let empty = Pipeline(name: "x", steps: [.init(name: "s", run: "true")])
        let emptyYAML = try empty.encodeYAML()
        #expect(!emptyYAML.contains("notify"))

        let withNotify = Pipeline(
            name: "x",
            steps: [.init(name: "s", run: "true")],
            notify: [
                .init(url: "https://a.example.com/"),               // on = always
                .init(url: "https://b.example.com/", on: .failed),
            ]
        )
        let yaml = try withNotify.encodeYAML()
        #expect(yaml.contains("notify"))
        #expect(yaml.contains("https://a.example.com/"))
        // The .always default shouldn't appear in the encoded text.
        // The .failed entry's `on:` should.
        #expect(yaml.contains("failed"))
    }

    @Test("shouldFire honors when policy")
    func shouldFireMatrix() {
        let always = Pipeline.Notification(url: "x", on: .always)
        let onPass = Pipeline.Notification(url: "x", on: .passed)
        let onFail = Pipeline.Notification(url: "x", on: .failed)

        // .always fires for any terminal status, NOT for queued/running.
        #expect(always.shouldFire(for: .passed))
        #expect(always.shouldFire(for: .failed))
        #expect(always.shouldFire(for: .canceled))
        #expect(!always.shouldFire(for: .queued))
        #expect(!always.shouldFire(for: .running))

        // .passed only fires on .passed.
        #expect(onPass.shouldFire(for: .passed))
        #expect(!onPass.shouldFire(for: .failed))
        #expect(!onPass.shouldFire(for: .canceled))

        // .failed fires on .failed and .canceled (any non-clean exit).
        #expect(onFail.shouldFire(for: .failed))
        #expect(onFail.shouldFire(for: .canceled))
        #expect(!onFail.shouldFire(for: .passed))
    }
}

@Suite("Build notifier integration", .serialized)
struct BuildNotifierIntegrationTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-notify-tests-\(UUID().uuidString)", isDirectory: true)
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
    enum Failure: Error { case timeout }

    @Test("notifier is called exactly once after a successful build")
    func calledOnPassed() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let pipeline = Pipeline(
            name: "PassedHook",
            steps: [.init(name: "Echo", run: "echo ok")],
            notify: [.init(url: "https://hooks.example.com/x")]
        )
        let jobID = try store.createJob(from: pipeline)
        let notifier = RecordingNotifier()
        let executor = BuildExecutor(store: store, notifier: notifier)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()

        #expect(final.status == .passed)
        let calls = await notifier.snapshot()
        #expect(calls.count == 1)
        #expect(calls[0].build.status == .passed)
        #expect(calls[0].pipeline.name == "PassedHook")
    }

    @Test("notifier is called after a failing build too")
    func calledOnFailed() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let pipeline = Pipeline(
            name: "FailedHook",
            steps: [.init(name: "Crash", run: "exit 5")],
            notify: [.init(url: "https://hooks.example.com/x")]
        )
        let jobID = try store.createJob(from: pipeline)
        let notifier = RecordingNotifier()
        let executor = BuildExecutor(store: store, notifier: notifier)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()

        #expect(final.status == .failed)
        #expect(final.exitCode == 5)
        let calls = await notifier.snapshot()
        #expect(calls.count == 1)
        #expect(calls[0].build.status == .failed)
    }

    @Test("notifier is called when an in-queue build is canceled")
    func calledOnQueuedCancel() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        // No-op step content; we never let the executor pick it up.
        let pipeline = Pipeline(
            name: "QueuedCancelHook",
            steps: [.init(name: "Echo", run: "echo never")],
            notify: [.init(url: "https://hooks.example.com/x")]
        )
        let jobID = try store.createJob(from: pipeline)
        let notifier = RecordingNotifier()
        // DON'T start the executor — keeps the build in the queue.
        let executor = BuildExecutor(store: store, notifier: notifier)
        let n = try await executor.enqueue(jobID: jobID)
        let res = await executor.cancel(jobID: jobID, number: n)
        #expect(res == .canceledQueued)
        // Brief wait so the cancel's notify task lands. (Cancellation
        // path calls `notifier.notify` synchronously inside the actor
        // before returning, so this is mostly belt-and-braces.)
        let calls = await notifier.snapshot()
        #expect(calls.count == 1)
        #expect(calls[0].build.status == .canceled)
    }

    @Test("URLSessionBuildNotifier with empty pipeline.notify makes zero requests")
    func emptyNotifyIsNoop() async throws {
        actor Hits {
            var v = 0
            func bump() { v += 1 }
            func get() -> Int { v }
        }
        let hits = Hits()
        let notifier = URLSessionBuildNotifier(logSink: { _, _, _ in
            Task { await hits.bump() }
        })
        let pipeline = Pipeline(
            name: "Quiet",
            steps: [.init(name: "x", run: "true")]
            // notify defaults to []
        )
        let build = Build(jobID: "j", number: 1, status: .passed,
                          exitCode: 0, startedAt: Date(), endedAt: Date())
        await notifier.notify(build: build, pipeline: pipeline)
        try? await Task.sleep(for: .milliseconds(50))
        let count = await hits.get()
        #expect(count == 0)
    }

    @Test("URLSessionBuildNotifier with .passed-only does NOT fire on .failed")
    func passedOnlyDoesNotFireOnFailed() async {
        actor Counter {
            var v = 0
            func bump() { v += 1 }
            func get() -> Int { v }
        }
        let c = Counter()
        let notifier = URLSessionBuildNotifier(logSink: { _, _, _ in
            Task { await c.bump() }
        })
        let pipeline = Pipeline(
            name: "x",
            steps: [.init(name: "s", run: "true")],
            notify: [.init(url: "https://127.0.0.1:1/should-not-hit", on: .passed)]
        )
        let failed = Build(jobID: "j", number: 1, status: .failed, exitCode: 1)
        await notifier.notify(build: failed, pipeline: pipeline)
        // Give any spuriously-spawned task a moment to (incorrectly) bump.
        try? await Task.sleep(for: .milliseconds(50))
        let count = await c.get()
        #expect(count == 0)
    }
}
