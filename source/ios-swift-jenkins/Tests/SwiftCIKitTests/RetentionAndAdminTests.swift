import Foundation
import Testing
import Vapor
import VaporTesting
@testable import SwiftCIKit

@Suite("Build retention (Phase 10)", .serialized)
struct BuildRetentionTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-retention-tests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("pruneBuilds keeps the last N builds and removes the rest")
    func pruneKeepsLast() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Prune", steps: [.init(name: "s", run: "true")]))
        // Create 5 builds manually.
        for _ in 0..<5 {
            _ = try store.createBuild(jobID: jobID)
        }
        #expect(try store.listBuildNumbers(jobID: jobID) == [1, 2, 3, 4, 5])

        let removed = try store.pruneBuilds(jobID: jobID, keepLast: 2)
        #expect(removed == [1, 2, 3])
        #expect(try store.listBuildNumbers(jobID: jobID) == [4, 5])

        // Confirm on-disk dirs are actually gone.
        let dir1 = store.buildDir(jobID: jobID, number: 1)
        #expect(!FileManager.default.fileExists(atPath: dir1.path))
        let dir5 = store.buildDir(jobID: jobID, number: 5)
        #expect(FileManager.default.fileExists(atPath: dir5.path))
    }

    @Test("pruneBuilds is a no-op when count <= keepLast")
    func pruneNoop() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "P", steps: [.init(name: "s", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        _ = try store.createBuild(jobID: jobID)

        let removed = try store.pruneBuilds(jobID: jobID, keepLast: 10)
        #expect(removed.isEmpty)
        #expect(try store.listBuildNumbers(jobID: jobID) == [1, 2])
    }

    @Test("pruneBuilds defensively keeps at least 1 when keepLast <= 0")
    func pruneMinimumOne() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "P", steps: [.init(name: "s", run: "true")]))
        for _ in 0..<3 { _ = try store.createBuild(jobID: jobID) }

        let removed = try store.pruneBuilds(jobID: jobID, keepLast: 0)
        #expect(removed == [1, 2])
        #expect(try store.listBuildNumbers(jobID: jobID) == [3])
    }

    @Test("Pipeline.retention schema round-trips through YAML")
    func retentionSchema() throws {
        // With retention.
        let yaml = """
        name: WithRetention
        steps:
          - name: s
            run: "true"
        retention:
          maxBuilds: 7
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.retention?.maxBuilds == 7)

        // Without retention.
        let yaml2 = """
        name: WithoutRetention
        steps:
          - name: s
            run: "true"
        """
        let p2 = try Pipeline.decode(yaml: yaml2)
        #expect(p2.retention == nil)

        // Encode omits when nil.
        let empty = Pipeline(name: "x", steps: [.init(name: "s", run: "true")])
        let emptyYAML = try empty.encodeYAML()
        #expect(!emptyYAML.contains("retention"))
    }

    @Test("BuildExecutor honors pipeline.retention.maxBuilds")
    func executorHonorsPipelineRetention() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        // Pipeline says keep last 2.
        let pipeline = Pipeline(
            name: "RetainTwo",
            steps: [.init(name: "Echo", run: "echo ok")],
            retention: .init(maxBuilds: 2)
        )
        let jobID = try store.createJob(from: pipeline)
        let executor = BuildExecutor(store: store, defaultRetention: 100)
        await executor.start()
        for _ in 0..<4 {
            _ = try await executor.enqueue(jobID: jobID)
        }
        // Wait for the last build to reach terminal — by then prune
        // has fired for every earlier completion too.
        _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 4)
        await executor.stop()

        let remaining = try store.listBuildNumbers(jobID: jobID)
        #expect(remaining == [3, 4])
    }

    @Test("BuildExecutor falls back to defaultRetention when pipeline.retention is nil")
    func executorUsesDefault() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let pipeline = Pipeline(
            name: "RetainDefault",
            steps: [.init(name: "Echo", run: "echo ok")]
            // retention: nil
        )
        let jobID = try store.createJob(from: pipeline)
        // defaultRetention = 1 — executor should keep only the latest
        // build after every prune.
        let executor = BuildExecutor(store: store, defaultRetention: 1)
        await executor.start()
        for _ in 0..<3 {
            _ = try await executor.enqueue(jobID: jobID)
        }
        _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 3)
        await executor.stop()

        let remaining = try store.listBuildNumbers(jobID: jobID)
        #expect(remaining == [3])
    }
}

@Suite("Admin token auth (Phase 11)", .serialized)
struct AdminAuthTests {
    static func withConfiguredApp<T>(
        adminToken: String? = nil,
        _ body: @Sendable (Vapor.Application, JobStore, BuildExecutor) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-admin-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)
        let executor = BuildExecutor(store: store)
        await executor.start()
        let result: T
        do {
            result = try await withApp { app in
                SwiftCIApp.configure(app, store: store, executor: executor,
                                     adminToken: adminToken)
                return try await body(app, store, executor)
            }
        } catch {
            await executor.stop()
            throw error
        }
        await executor.stop()
        return result
    }

    @Test("POST /api/jobs without Authorization → 401 when adminToken set")
    func postJobsRequiresAuth() async throws {
        try await Self.withConfiguredApp(adminToken: "admin-secret") { app, _, _ in
            var buf = ByteBuffer(); buf.writeString("name: x\nsteps: [{name: s, run: \"true\"}]")
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("POST /api/jobs with correct Bearer succeeds when adminToken set")
    func postJobsAcceptsBearer() async throws {
        try await Self.withConfiguredApp(adminToken: "admin-secret") { app, _, _ in
            var buf = ByteBuffer(); buf.writeString("name: x\nsteps: [{name: s, run: \"true\"}]")
            let headers = HTTPHeaders([("Authorization", "Bearer admin-secret")])
            try await app.testing().test(.POST, "/api/jobs",
                                         headers: headers, body: buf) { res in
                #expect(res.status == .created)
            }
        }
    }

    @Test("POST /api/jobs with wrong Bearer → 401")
    func postJobsRejectsWrongBearer() async throws {
        try await Self.withConfiguredApp(adminToken: "admin-secret") { app, _, _ in
            var buf = ByteBuffer(); buf.writeString("name: x\nsteps: [{name: s, run: \"true\"}]")
            let headers = HTTPHeaders([("Authorization", "Bearer nope")])
            try await app.testing().test(.POST, "/api/jobs",
                                         headers: headers, body: buf) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("POST /api/jobs/:id/trigger requires Bearer when adminToken set")
    func triggerRequiresAuth() async throws {
        try await Self.withConfiguredApp(adminToken: "admin-secret") { app, _, _ in
            // First create a job, with auth.
            var buf = ByteBuffer(); buf.writeString("name: HookedJob\nsteps: [{name: s, run: \"true\"}]")
            var jobID = ""
            let okHeaders = HTTPHeaders([("Authorization", "Bearer admin-secret")])
            try await app.testing().test(.POST, "/api/jobs",
                                         headers: okHeaders, body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            // Now try to trigger without auth → 401.
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .unauthorized)
            }
            // With auth → 202.
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger",
                                         headers: okHeaders) { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("GET routes stay open even when adminToken is set")
    func readsStayOpen() async throws {
        try await Self.withConfiguredApp(adminToken: "admin-secret") { app, _, _ in
            try await app.testing().test(.GET, "/health") { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/api/jobs") { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("All routes work without auth when adminToken is nil")
    func defaultIsOpen() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            var buf = ByteBuffer(); buf.writeString("name: x\nsteps: [{name: s, run: \"true\"}]")
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                #expect(res.status == .created)
            }
        }
    }

    @Test("POST /webhook/:id is NOT gated by adminToken")
    func webhookNotGatedByAdmin() async throws {
        try await Self.withConfiguredApp(adminToken: "admin-secret") { app, _, _ in
            // Create a job WITH admin auth.
            var buf = ByteBuffer(); buf.writeString("name: WebhookJob\nsteps: [{name: s, run: \"true\"}]")
            var jobID = ""
            let okHeaders = HTTPHeaders([("Authorization", "Bearer admin-secret")])
            try await app.testing().test(.POST, "/api/jobs",
                                         headers: okHeaders, body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            // Webhook should still work without admin auth (since
            // webhookToken is nil — webhook stays open).
            try await app.testing().test(.POST, "/webhook/\(jobID)") { res in
                #expect(res.status == .accepted)
            }
        }
    }
}
