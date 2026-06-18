import Foundation
import Testing
@testable import SwiftCIKit

@Suite("StepRunner")
struct StepRunnerTests {
    @Test("runs a successful echo command and captures stdout")
    func successEcho() async throws {
        let step = Pipeline.Step(name: "Hello", run: "echo hello-from-runner")
        let result = try await StepRunner().run(step)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello-from-runner"))
    }

    @Test("propagates a non-zero exit code")
    func failure() async throws {
        // `exit 7` exits with code 7 on both cmd.exe and /bin/sh.
        let step = Pipeline.Step(name: "Boom", run: "exit 7")
        let result = try await StepRunner().run(step)
        #expect(result.exitCode == 7)
    }
}

@Suite("BuildExecutor", .serialized)
struct BuildExecutorTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-exec-tests-\(UUID().uuidString)", isDirectory: true)
        return JobStore(root: url)
    }

    static func cleanUp(_ store: JobStore) {
        try? FileManager.default.removeItem(at: store.root)
    }

    static func waitForTerminal(
        store: JobStore,
        jobID: String,
        number: Int,
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
        if let b = try store.loadBuild(jobID: jobID, number: number) {
            return b
        }
        throw Failure.timeout
    }

    enum Failure: Error { case timeout }

    @Test("enqueue throws JobStoreError.noSuchJob for an unknown job")
    func enqueueMissingJob() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let executor = BuildExecutor(store: store)
        await executor.start()
        defer { Task { await executor.stop() } }
        await #expect(throws: JobStoreError.self) {
            _ = try await executor.enqueue(jobID: "does-not-exist")
        }
    }

    @Test("runs a single passing step end-to-end")
    func runPassing() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Echo",
            steps: [.init(name: "Hi", run: "echo hello-from-exec")]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await Self.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .passed)
        #expect(build.exitCode == 0)
        let log = try store.readLog(jobID: jobID, number: number)
        #expect(log.contains("hello-from-exec"))
        #expect(log.contains("passed"))
    }

    @Test("stops on first failing step; later steps don't run")
    func stopsOnFailure() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "StopShort",
            steps: [
                .init(name: "Will-Fail",  run: "exit 3"),
                .init(name: "Skipped",    run: "echo SHOULD_NOT_APPEAR"),
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let build = try await Self.waitForTerminal(
            store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(build.status == .failed)
        #expect(build.exitCode == 3)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(!log.contains("SHOULD_NOT_APPEAR"))
    }

    @Test("processes the queue in FIFO order")
    func fifo() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Marker",
            steps: [.init(name: "echo", run: "echo done")]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let n1 = try await executor.enqueue(jobID: jobID)
        let n2 = try await executor.enqueue(jobID: jobID)
        let n3 = try await executor.enqueue(jobID: jobID)
        let actual: [Int] = [n1, n2, n3]
        #expect(actual == [1, 2, 3])
        _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 2)
        _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 3)
        await executor.stop()
        let numbers = try store.listBuildNumbers(jobID: jobID)
        #expect(numbers == [1, 2, 3])
    }

    @Test("stop() drops idle worker without deadlock")
    func stopWhileIdle() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let executor = BuildExecutor(store: store)
        await executor.start()
        await executor.stop()  // must return promptly
    }

    @Test("snapshotQueue reports head-first order, 1-based positions, and queuedAt")
    func snapshotQueue() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Q", steps: [.init(name: "x", run: "true")]))
        // Build the executor but do NOT start the worker, so the
        // queue stays full while we snapshot it.
        let executor = BuildExecutor(store: store)
        let before = Date()
        let n1 = try await executor.enqueue(jobID: jobID)
        let n2 = try await executor.enqueue(jobID: jobID)
        let n3 = try await executor.enqueue(jobID: jobID)
        let after = Date()

        let snap = await executor.snapshotQueue()
        #expect(snap.count == 3)
        #expect(snap.map(\.number) == [n1, n2, n3])
        #expect(snap.map(\.position) == [1, 2, 3])
        #expect(snap.allSatisfy { $0.jobID == jobID })
        for entry in snap {
            #expect(entry.queuedAt >= before)
            #expect(entry.queuedAt <= after)
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 32: when {} stage gating
    // ──────────────────────────────────────────────────────────────

    @Test("step with a false `when` condition is skipped, build still passes")
    func whenSkipsStep() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Gated",
            steps: [
                .init(
                    name: "Skipped",
                    run: "echo SHOULD_NOT_APPEAR",
                    condition: .branch("main")  // BRANCH_NAME unset → false
                ),
                .init(name: "Always", run: "echo ran-always"),
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let build = try await Self.waitForTerminal(
            store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(build.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("skipped (when condition not met)"))
        #expect(!log.contains("SHOULD_NOT_APPEAR"))
        #expect(log.contains("ran-always"))
    }

    @Test("step with a true `when` condition runs normally")
    func whenRunsStep() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Gated",
            steps: [
                .init(
                    name: "Gate",
                    run: "echo gated-step-ran",
                    env: ["BRANCH_NAME": "main"],
                    condition: .branch("main")
                ),
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let build = try await Self.waitForTerminal(
            store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(build.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("gated-step-ran"))
    }
}

@Suite("Build status persistence")
struct BuildStatusTests {
    @Test("createBuild assigns sequential numbers")
    func sequentialNumbers() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-buildnums-\(UUID().uuidString)", isDirectory: true)
        let store = JobStore(root: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Seq", steps: [.init(name: "x", run: "true")]))
        let b1 = try store.createBuild(jobID: jobID)
        let b2 = try store.createBuild(jobID: jobID)
        let b3 = try store.createBuild(jobID: jobID)
        #expect(b1.number == 1)
        #expect(b2.number == 2)
        #expect(b3.number == 3)
        #expect(b1.status == .queued)
    }

    @Test("updateBuild round-trips through loadBuild")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-buildrt-\(UUID().uuidString)", isDirectory: true)
        let store = JobStore(root: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let jobID = try store.createJob(from: Pipeline(
            name: "RT", steps: [.init(name: "x", run: "true")]))
        var build = try store.createBuild(jobID: jobID)
        build.status = .passed
        build.exitCode = 0
        // Phase 21: createBuild stamps `queuedAt = Date()` with
        // sub-second precision; the ISO8601 encoder used by JobStore
        // truncates sub-seconds, so override with a whole-second value
        // so the loaded build compares byte-for-byte equal.
        build.queuedAt  = Date(timeIntervalSince1970: 1_699_999_990)
        build.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        build.endedAt   = Date(timeIntervalSince1970: 1_700_000_010)
        try store.updateBuild(build)
        let loaded = try store.loadBuild(jobID: jobID, number: build.number)
        #expect(loaded == build)
    }

    @Test("readLog with tail returns the last N lines")
    func tailLog() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-tail-\(UUID().uuidString)", isDirectory: true)
        let store = JobStore(root: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Tail", steps: [.init(name: "x", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        for i in 1...150 {
            try store.appendLog(jobID: jobID, number: 1, "line \(i)\n")
        }
        let tail = try store.readLog(jobID: jobID, number: 1, tail: 100)
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        // 100 actual lines + the trailing empty after last "\n".
        #expect(lines.count == 101)
        #expect(lines.first == "line 51")
        #expect(lines[99] == "line 150")
    }
}

@Suite("BuildExecutor parallel (Phase 36)", .serialized)
struct BuildExecutorParallelTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-par-tests-\(UUID().uuidString)", isDirectory: true)
        return JobStore(root: url)
    }
    static func cleanUp(_ store: JobStore) {
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("runs all branches concurrently and the build passes when every branch exits 0")
    func parallelAllPass() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Fan",
            steps: [
                .init(name: "fan", run: "", parallel: [
                    .init(name: "a", steps: [.init(name: "a1", run: "echo BRANCH-A-OK")]),
                    .init(name: "b", steps: [.init(name: "b1", run: "echo BRANCH-B-OK")]),
                    .init(name: "c", steps: [.init(name: "c1", run: "echo BRANCH-C-OK")]),
                ]),
            ]))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await BuildExecutorTests.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .passed)
        let log = try store.readLog(jobID: jobID, number: number)
        #expect(log.contains("BRANCH-A-OK"))
        #expect(log.contains("BRANCH-B-OK"))
        #expect(log.contains("BRANCH-C-OK"))
        #expect(log.contains("parallel group passed"))
        #expect(log.contains("[a]"))
        #expect(log.contains("[b]"))
        #expect(log.contains("[c]"))
    }

    @Test("any branch failure fails the group and the build")
    func parallelOneFails() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Fan",
            steps: [
                .init(name: "fan", run: "", parallel: [
                    .init(name: "ok", steps: [.init(name: "x", run: "echo OK")]),
                    .init(name: "bad", steps: [.init(name: "y", run: "exit 7")]),
                ]),
            ]))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await BuildExecutorTests.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .failed)
        #expect(build.exitCode == 7)
        let log = try store.readLog(jobID: jobID, number: number)
        #expect(log.contains("parallel group failed"))
    }

    @Test("subsequent sequential step does not run after a failed parallel group")
    func parallelShortCircuits() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Fan",
            steps: [
                .init(name: "fan", run: "", parallel: [
                    .init(name: "bad", steps: [.init(name: "y", run: "exit 3")]),
                ]),
                .init(name: "after", run: "echo SHOULD-NOT-RUN"),
            ]))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await BuildExecutorTests.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .failed)
        let log = try store.readLog(jobID: jobID, number: number)
        #expect(!log.contains("SHOULD-NOT-RUN"))
    }
}


@Suite("BuildExecutor credentials (Phase 37)", .serialized)
struct BuildExecutorCredentialTests {
    @Test("a step's credentials are resolved and bound into its environment")
    func resolveAndBind() async throws {
        let store = BuildExecutorTests.makeTempStore()
        defer { BuildExecutorTests.cleanUp(store) }
        // CredentialStore writes credentials.json into the store root,
        // which doesn't exist until JobStore creates it on first job.
        // Create the directory up front so the initial save succeeds.
        try? FileManager.default.createDirectory(at: store.root,
            withIntermediateDirectories: true)
        let creds = CredentialStore(jobStore: store)
        _ = try await creds.create(id: "smoke", value: "s3cret-value")
        let jobID = try store.createJob(from: Pipeline(
            name: "Cred",
            steps: [.init(
                name: "deploy",
                run: "echo done",
                credentials: [.init(credentialsId: "smoke", variable: "FOO")])
            ]))
        let executor = BuildExecutor(store: store, credentialStore: creds)
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await BuildExecutorTests.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .passed)
        let log = try store.readLog(jobID: jobID, number: number)
        #expect(log.contains("credentials: bound [FOO]"))
        // Value MUST NEVER appear in the log; the banner names only the
        // variable. This is the redaction guarantee for Phase 37.
        #expect(!log.contains("s3cret-value"))
    }

    @Test("missing credential id fails the build")
    func missingCredentialFails() async throws {
        let store = BuildExecutorTests.makeTempStore()
        defer { BuildExecutorTests.cleanUp(store) }
        let creds = CredentialStore(jobStore: store)
        let jobID = try store.createJob(from: Pipeline(
            name: "Cred",
            steps: [.init(
                name: "bad",
                run: "echo should-not-run",
                credentials: [.init(credentialsId: "nope", variable: "X")])
            ]))
        let executor = BuildExecutor(store: store, credentialStore: creds)
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await BuildExecutorTests.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .failed)
        let log = try store.readLog(jobID: jobID, number: number)
        #expect(log.contains("step credential resolution failed"))
    }

    @Test("non-empty credentials with no credentialStore fails the build")
    func noCredentialStoreFails() async throws {
        let store = BuildExecutorTests.makeTempStore()
        defer { BuildExecutorTests.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "NoStore",
            steps: [.init(
                name: "bad",
                run: "echo nope",
                credentials: [.init(credentialsId: "x", variable: "X")])
            ]))
        let executor = BuildExecutor(store: store)  // no credentialStore
        await executor.start()
        let number = try await executor.enqueue(jobID: jobID)
        let build = try await BuildExecutorTests.waitForTerminal(
            store: store, jobID: jobID, number: number)
        await executor.stop()
        #expect(build.status == .failed)
    }
}
