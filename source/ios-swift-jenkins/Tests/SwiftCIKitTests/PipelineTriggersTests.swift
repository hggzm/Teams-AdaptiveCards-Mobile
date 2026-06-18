import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Pipeline triggers (Phase 13)", .serialized)
struct PipelineTriggersTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-trigger-tests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("triggers: schema parses from YAML and round-trips")
    func schema() throws {
        let yaml = """
        name: Upstream
        steps:
          - name: s
            run: "true"
        triggers:
          - downstream-1
          - downstream-2
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.triggers == ["downstream-1", "downstream-2"])

        // Missing → empty list, omitted on encode.
        let empty = Pipeline(name: "x", steps: [.init(name: "s", run: "true")])
        let emptyYAML = try empty.encodeYAML()
        #expect(!emptyYAML.contains("triggers"))

        // Non-empty → included.
        let withTrig = Pipeline(name: "x",
                                steps: [.init(name: "s", run: "true")],
                                triggers: ["d-1"])
        let yaml2 = try withTrig.encodeYAML()
        #expect(yaml2.contains("triggers"))
        #expect(yaml2.contains("d-1"))
    }

    @Test("Passing upstream build enqueues each downstream job")
    func passedFiresTriggers() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }

        // Two downstream jobs.
        let downA = try store.createJob(from: Pipeline(
            name: "DownA", steps: [.init(name: "s", run: "echo a")]))
        let downB = try store.createJob(from: Pipeline(
            name: "DownB", steps: [.init(name: "s", run: "echo b")]))

        // Upstream with triggers to both.
        let upstream = try store.createJob(from: Pipeline(
            name: "Upstream",
            steps: [.init(name: "s", run: "echo upstream-ok")],
            triggers: [downA, downB]
        ))

        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: upstream)
        let upBuild = try await Self.waitForTerminal(
            store: store, jobID: upstream, number: 1)
        #expect(upBuild.status == .passed)

        // Wait for both downstream builds to land.
        _ = try await Self.waitForTerminal(store: store, jobID: downA, number: 1)
        _ = try await Self.waitForTerminal(store: store, jobID: downB, number: 1)
        await executor.stop()

        // Both downstream jobs have a build #1 in terminal state.
        let aNumbers = try store.listBuildNumbers(jobID: downA)
        let bNumbers = try store.listBuildNumbers(jobID: downB)
        #expect(aNumbers == [1])
        #expect(bNumbers == [1])

        // Upstream's log mentions the triggers.
        let log = try store.readLog(jobID: upstream, number: 1)
        #expect(log.contains("trigger: enqueued downstream '\(downA)'"))
        #expect(log.contains("trigger: enqueued downstream '\(downB)'"))
    }

    @Test("Failed upstream build does NOT fire triggers")
    func failedSkipsTriggers() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let down = try store.createJob(from: Pipeline(
            name: "DownX", steps: [.init(name: "s", run: "echo x")]))
        let upstream = try store.createJob(from: Pipeline(
            name: "FailingUpstream",
            steps: [.init(name: "Crash", run: "exit 3")],
            triggers: [down]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: upstream)
        let upBuild = try await Self.waitForTerminal(
            store: store, jobID: upstream, number: 1)
        #expect(upBuild.status == .failed)
        // Give the executor a beat to potentially (incorrectly) fire.
        try await Task.sleep(for: .milliseconds(200))
        await executor.stop()

        let downNumbers = try store.listBuildNumbers(jobID: down)
        #expect(downNumbers.isEmpty)
        let log = try store.readLog(jobID: upstream, number: 1)
        #expect(!log.contains("trigger: enqueued"))
    }

    @Test("Missing downstream job logs a failure but doesn't fail the upstream")
    func missingDownstreamSurvives() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let upstream = try store.createJob(from: Pipeline(
            name: "OrphanTrigger",
            steps: [.init(name: "s", run: "echo ok")],
            triggers: ["does-not-exist-aaaaaaaa"]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: upstream)
        let upBuild = try await Self.waitForTerminal(
            store: store, jobID: upstream, number: 1)
        await executor.stop()

        #expect(upBuild.status == .passed)
        let log = try store.readLog(jobID: upstream, number: 1)
        #expect(log.contains("trigger: FAILED to enqueue downstream 'does-not-exist-aaaaaaaa'"))
    }

    @Test("Canceled upstream build does NOT fire triggers")
    func canceledSkipsTriggers() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let down = try store.createJob(from: Pipeline(
            name: "DownC", steps: [.init(name: "s", run: "echo c")]))
        let upstream = try store.createJob(from: Pipeline(
            name: "CancelUpstream",
            steps: [.init(name: "s", run: "echo will-be-canceled")],
            triggers: [down]
        ))
        let executor = BuildExecutor(store: store)
        // Don't start the executor; cancel while queued.
        let n = try await executor.enqueue(jobID: upstream)
        let res = await executor.cancel(jobID: upstream, number: n)
        #expect(res == .canceledQueued)

        let upBuild = try #require(try store.loadBuild(jobID: upstream, number: n))
        #expect(upBuild.status == .canceled)

        let downNumbers = try store.listBuildNumbers(jobID: down)
        #expect(downNumbers.isEmpty)
    }
}
