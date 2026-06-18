import Foundation
import Testing
import Vapor
import VaporTesting
@testable import SwiftCIKit

@Suite("SwiftCIApp routes", .serialized)
struct SwiftCIAppTests {
    /// Helper: spin up a Vapor `Application` with `SwiftCIApp.configure(...)`
    /// pointed at a fresh per-test temp data dir. A `BuildExecutor` is
    /// started for the duration of the test and stopped at teardown.
    ///
    /// `webhookToken` defaults to nil (open webhook); tests that exercise
    /// the auth path pass an explicit value.
    static func withConfiguredApp<T>(
        webhookToken: String? = nil,
        adminToken: String? = nil,
        tokenStore: APITokenStore? = nil,
        _ body: @Sendable (Application, JobStore, BuildExecutor) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-app-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)
        let executor = BuildExecutor(store: store)
        await executor.start()
        let result: T
        do {
            result = try await withApp { app in
                SwiftCIApp.configure(app, store: store, executor: executor,
                                     webhookToken: webhookToken,
                                     adminToken: adminToken,
                                     tokenStore: tokenStore)
                return try await body(app, store, executor)
            }
        } catch {
            await executor.stop()
            throw error
        }
        await executor.stop()
        return result
    }

    @Test("GET /version responds with the product name and version")
    func versionEndpoint() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/version") { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(SwiftCIApp.productName))
                #expect(res.body.string.contains(SwiftCIApp.version))
            }
        }
    }

    @Test("GET /health responds with ok")
    func health() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/health") { res in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            }
        }
    }

    @Test("GET /api/jobs is empty for a fresh store")
    func listEmpty() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/api/jobs") { res in
                #expect(res.status == .ok)
                struct Payload: Codable { let jobs: [String] }
                let decoded = try JSONDecoder().decode(Payload.self, from: Data(res.body.string.utf8))
                #expect(decoded.jobs.isEmpty)
            }
        }
    }

    @Test("POST /api/jobs persists, GET /api/jobs/:id returns the YAML back")
    func createAndFetch() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            let yamlIn = """
            name: Smoke
            steps:
              - name: One
                run: echo one
              - name: Two
                run: echo two
            """
            var buf = ByteBuffer()
            buf.writeString(yamlIn)

            var createdID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                #expect(res.status == .created)
                #expect(res.headers["location"].first?.hasPrefix("/api/jobs/") == true)
                struct Payload: Codable { let id: String; let name: String }
                let decoded = try JSONDecoder().decode(Payload.self, from: Data(res.body.string.utf8))
                #expect(decoded.name == "Smoke")
                #expect(decoded.id.hasPrefix("smoke-"))
                createdID = decoded.id
            }

            #expect(!createdID.isEmpty)

            try await app.testing().test(.GET, "/api/jobs") { res in
                #expect(res.status == .ok)
                struct Payload: Codable { let jobs: [String] }
                let decoded = try JSONDecoder().decode(Payload.self, from: Data(res.body.string.utf8))
                #expect(decoded.jobs.contains(createdID))
            }

            try await app.testing().test(.GET, "/api/jobs/\(createdID)") { res in
                #expect(res.status == .ok)
                let pipeline = try Pipeline.decode(yaml: res.body.string)
                #expect(pipeline.name == "Smoke")
                #expect(pipeline.steps.map(\.run) == ["echo one", "echo two"])
            }
        }
    }

    @Test("POST /api/jobs rejects an empty body")
    func rejectEmpty() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.POST, "/api/jobs") { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/jobs rejects malformed YAML")
    func rejectMalformed() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            var buf = ByteBuffer()
            buf.writeString("name: [unterminated")
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("GET /api/jobs/:id 404s for an unknown id")
    func unknownJob() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/api/jobs/does-not-exist-00000000") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Build routes (Phase 3)
    // ──────────────────────────────────────────────────────────────────

    /// Poll the on-disk build status until it reaches a terminal state
    /// or the deadline passes. Returns the last observed `Build` (which
    /// may still be `.queued` or `.running` if the timeout fires).
    static func waitForTerminal(
        store: JobStore,
        jobID: String,
        number: Int,
        timeout: Duration = .seconds(30)
    ) async throws -> Build {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let build = try store.loadBuild(jobID: jobID, number: number),
               build.status.isTerminal {
                return build
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let build = try store.loadBuild(jobID: jobID, number: number) {
            return build
        }
        throw TestError.timeout("build #\(number) of \(jobID) never reached terminal status")
    }

    enum TestError: Error { case timeout(String) }

    @Test("POST /api/jobs/:id/trigger 404s for unknown job")
    func triggerUnknownJob() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.POST, "/api/jobs/does-not-exist/trigger") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/jobs/:id/trigger queues, executor runs to passed for echo step")
    func triggerEchoPasses() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            // Create a job that echoes something — must succeed on any host.
            let yamlIn = """
            name: Echo
            steps:
              - name: Hello
                run: echo hello from swiftci
            """
            var buf = ByteBuffer()
            buf.writeString(yamlIn)

            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                #expect(res.status == .created)
                struct P: Codable { let id: String; let name: String }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                jobID = d.id
            }

            var buildNumber = 0
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
                #expect(res.headers["location"].first == "/api/jobs/\(jobID)/builds/1")
                struct P: Codable { let number: Int }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                buildNumber = d.number
            }
            #expect(buildNumber == 1)

            let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
            #expect(final.status == .passed)
            #expect(final.exitCode == 0)
            #expect(final.startedAt != nil)
            #expect(final.endedAt != nil)

            // Build detail endpoint surfaces status + log including stdout.
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/1") { res in
                #expect(res.status == .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let body = Data(res.body.string.utf8)
                struct P: Codable { let build: Build; let log: String }
                let d = try decoder.decode(P.self, from: body)
                #expect(d.build.status == .passed)
                #expect(d.log.contains("hello from swiftci"))
                #expect(d.log.contains("step 1/1"))
                #expect(d.log.contains("exit=0"))
            }

            // Build list includes #1.
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds") { res in
                #expect(res.status == .ok)
                struct P: Codable { let builds: [Int] }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                #expect(d.builds == [1])
            }
        }
    }

    @Test("Triggering twice yields monotonically-increasing build numbers")
    func triggerTwice() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            // Make a fast no-op job.
            let yaml = """
            name: NoOp
            steps:
              - name: First
                run: echo first
            """
            var buf = ByteBuffer(); buf.writeString(yaml)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
            }
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
                struct P: Codable { let number: Int }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                #expect(d.number == 2)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 2)
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds") { res in
                struct P: Codable { let builds: [Int] }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                #expect(d.builds == [1, 2])
            }
        }
    }

    @Test("Failing step marks build as failed with the step's exit code")
    func triggerFails() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            // `exit 7` on cmd.exe AND /bin/sh both return 7.
            let yaml = """
            name: Boom
            steps:
              - name: Crash
                run: exit 7
            """
            var buf = ByteBuffer(); buf.writeString(yaml)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
            }
            let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
            #expect(final.status == .failed)
            #expect(final.exitCode == 7)
        }
    }

    // ──────────────────────────────────────────────────────────
    // Phase 33: trigger-time `parameters` body
    // ──────────────────────────────────────────────────────────

    @Test("POST /api/jobs/:id/trigger with parameters body persists overrides on the build")
    func triggerWithParameters() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let yaml = """
            name: ParamEcho
            steps:
              - name: Hi
                run: echo hi
            """
            var buf = ByteBuffer(); buf.writeString(yaml)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            // POST trigger with a parameters JSON body.
            var body = ByteBuffer()
            body.writeString(#"{"parameters":{"GREETING":"override","REGION":"us-west"}}"#)
            try await app.testing().test(
                .POST, "/api/jobs/\(jobID)/trigger",
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: body
            ) { res in
                #expect(res.status == .accepted)
            }
            let final = try await Self.waitForTerminal(
                store: store, jobID: jobID, number: 1)
            #expect(final.status == .passed)
            #expect(final.parameters?["GREETING"] == "override")
            #expect(final.parameters?["REGION"] == "us-west")

            // GET /api/jobs/:id/builds/:n surfaces parameters in the
            // serialized build.
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/1") { res in
                #expect(res.status == .ok)
                let decoder = JSONDecoder(usingISO8601: ())
                struct P: Codable { let build: Build; let log: String }
                let d = try decoder.decode(P.self, from: Data(res.body.string.utf8))
                #expect(d.build.parameters?["GREETING"] == "override")
            }
        }
    }

    @Test("POST /api/jobs/:id/trigger with empty body still works (back-compat)")
    func triggerEmptyBodyBackCompat() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let yaml = """
            name: NoParams
            steps:
              - name: Hi
                run: echo hi
            """
            var buf = ByteBuffer(); buf.writeString(yaml)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
            }
            let final = try await Self.waitForTerminal(
                store: store, jobID: jobID, number: 1)
            #expect(final.status == .passed)
            #expect(final.parameters == nil)
        }
    }

    @Test("POST /api/jobs/:id/trigger rejects non-string parameter values with 400")
    func triggerRejectsNonStringParameters() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            let yaml = """
            name: BadParams
            steps:
              - name: Hi
                run: echo hi
            """
            var buf = ByteBuffer(); buf.writeString(yaml)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            var body = ByteBuffer()
            body.writeString(#"{"parameters":{"COUNT":42}}"#)
            try await app.testing().test(
                .POST, "/api/jobs/\(jobID)/trigger",
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: body
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("GET /api/jobs/:id/builds/:n 404s for an unknown build")
    func unknownBuild() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            let yaml = """
            name: Empty
            steps:
              - name: Hi
                run: echo hi
            """
            var buf = ByteBuffer(); buf.writeString(yaml)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
            }
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/99") { res in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/notanumber") { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Webhook receiver (Phase 5)
    // ──────────────────────────────────────────────────────────────────

    /// Create a no-op job and return its id.
    static func createNoOpJob(_ app: Application) async throws -> String {
        let yaml = """
        name: Hook
        steps:
          - name: Echo
            run: echo hook
        """
        var buf = ByteBuffer(); buf.writeString(yaml)
        var jobID = ""
        try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
            struct P: Codable { let id: String; let name: String }
            jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
        }
        return jobID
    }

    @Test("POST /webhook/:id 404s for an unknown job (no token)")
    func webhookUnknownJob() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.POST, "/webhook/does-not-exist-00000000") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /webhook/:id queues a build when no token is configured")
    func webhookOpenAccepts() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/webhook/\(jobID)") { res in
                #expect(res.status == .accepted)
                #expect(res.headers["location"].first == "/api/jobs/\(jobID)/builds/1")
                struct P: Codable { let jobID: String; let number: Int }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                #expect(d.jobID == jobID)
                #expect(d.number == 1)
            }
            let final = try await Self.waitForTerminal(
                store: store, jobID: jobID, number: 1)
            #expect(final.status == .passed)
        }
    }

    @Test("POST /webhook/:id rejects requests without a token when configured")
    func webhookMissingToken() async throws {
        try await Self.withConfiguredApp(webhookToken: "s3cr3t") { app, _, _ in
            let jobID = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/webhook/\(jobID)") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("POST /webhook/:id rejects requests with the wrong token")
    func webhookWrongToken() async throws {
        try await Self.withConfiguredApp(webhookToken: "s3cr3t") { app, _, _ in
            let jobID = try await Self.createNoOpJob(app)
            let headers = HTTPHeaders([("X-Webhook-Token", "nope")])
            try await app.testing().test(.POST, "/webhook/\(jobID)",
                                         headers: headers) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("POST /webhook/:id accepts a request with the correct header token")
    func webhookHeaderToken() async throws {
        try await Self.withConfiguredApp(webhookToken: "s3cr3t") { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            let headers = HTTPHeaders([("X-Webhook-Token", "s3cr3t")])
            try await app.testing().test(.POST, "/webhook/\(jobID)",
                                         headers: headers) { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        }
    }

    @Test("POST /webhook/:id accepts a request with the correct ?token=...")
    func webhookQueryToken() async throws {
        try await Self.withConfiguredApp(webhookToken: "s3cr3t") { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            try await app.testing().test(
                .POST, "/webhook/\(jobID)?token=s3cr3t"
            ) { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        }
    }

    @Test("POST /webhook/:id persists request body to webhook.json (no token configured)")
    func webhookBodyPersisted() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            let body = #"{"ref":"refs/heads/main","sha":"deadbeef"}"#
            var buf = ByteBuffer(); buf.writeString(body)
            let headers = HTTPHeaders([
                ("content-type", "application/json"),
                ("x-github-event", "push"),
            ])
            try await app.testing().test(
                .POST, "/webhook/\(jobID)", headers: headers, body: buf
            ) { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
            let payload = try store.loadWebhookPayload(jobID: jobID, number: 1)
            #expect(payload != nil)
            #expect(payload?.body.contains("deadbeef") == true)
            #expect(payload?.headers["x-github-event"] == "push")
            #expect(payload?.headers["content-type"]?.contains("application/json") == true)
        }
    }

    @Test("X-Webhook-Token header is NOT persisted to webhook.json")
    func webhookTokenStripped() async throws {
        try await Self.withConfiguredApp(webhookToken: "s3cr3t") { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            let headers = HTTPHeaders([
                ("X-Webhook-Token", "s3cr3t"),
                ("content-type", "application/json"),
            ])
            var buf = ByteBuffer(); buf.writeString("{}")
            try await app.testing().test(
                .POST, "/webhook/\(jobID)", headers: headers, body: buf
            ) { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
            let payload = try store.loadWebhookPayload(jobID: jobID, number: 1)
            #expect(payload != nil)
            #expect(payload?.headers["x-webhook-token"] == nil)
            // Other headers still present.
            #expect(payload?.headers["content-type"]?.contains("application/json") == true)
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Artifacts (Phase 7)
    // ──────────────────────────────────────────────────────────────────

    /// Create a job + trigger a build with one step that writes a
    /// file marked as an artifact, then wait for the build to finish.
    /// Returns (jobID, buildNumber).
    static func triggerArtifactBuild(_ app: Application, store: JobStore)
        async throws -> (String, Int) {
        let yaml = """
        name: ArtifactsRoute
        steps:
          - name: MakeFile
            run: echo route-content > out.txt
            artifacts:
              - out.txt
        """
        var buf = ByteBuffer(); buf.writeString(yaml)
        var jobID = ""
        try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
            struct P: Codable { let id: String; let name: String }
            jobID = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8)).id
        }
        try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
            #expect(res.status == .accepted)
        }
        _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        return (jobID, 1)
    }

    @Test("GET /api/jobs/:id/builds/:n/artifacts lists collected names")
    func listArtifactsRoute() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let (jobID, n) = try await Self.triggerArtifactBuild(app, store: store)
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/\(n)/artifacts") { res in
                #expect(res.status == .ok)
                struct P: Codable { let artifacts: [String] }
                let d = try JSONDecoder().decode(P.self, from: Data(res.body.string.utf8))
                #expect(d.artifacts == ["out.txt"])
            }
        }
    }

    @Test("GET /api/jobs/:id/builds/:n/artifacts/:name streams the file")
    func downloadArtifactRoute() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let (jobID, n) = try await Self.triggerArtifactBuild(app, store: store)
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/\(n)/artifacts/out.txt") { res in
                #expect(res.status == .ok)
                #expect(res.headers["content-type"].first == "application/octet-stream")
                #expect(res.headers["content-disposition"].first?.contains("filename=\"out.txt\"") == true)
                #expect(res.body.string.contains("route-content"))
            }
        }
    }

    @Test("GET /api/jobs/:id/builds/:n/artifacts/:name 404s for unknown artifact")
    func unknownArtifactRoute() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let (jobID, n) = try await Self.triggerArtifactBuild(app, store: store)
            try await app.testing().test(.GET, "/api/jobs/\(jobID)/builds/\(n)/artifacts/does-not-exist") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Build cancellation (Phase 8)
    // ──────────────────────────────────────────────────────────────────

    @Test("POST /api/jobs/:id/builds/:n/cancel 404s for unknown build")
    func cancelRouteUnknownBuild() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.POST, "/api/jobs/no-such-job/builds/1/cancel") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/jobs/:id/builds/:n/cancel 409s for an already-terminal build")
    func cancelRouteTerminal() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/builds/1/cancel") { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 28: GET /api/builds/recent
    // ──────────────────────────────────────────────────────────────

    @Test("GET /api/builds/recent returns an empty list when no builds exist")
    func recentBuildsEmpty() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/api/builds/recent") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder().decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.limit == 20)
                #expect(d.builds.isEmpty)
            }
        }
    }

    @Test("GET /api/builds/recent rejects out-of-range limit with 400")
    func recentBuildsBadLimit() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/api/builds/recent?limit=0") { res in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/api/builds/recent?limit=201") { res in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/api/builds/recent?limit=abc") { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("GET /api/builds/recent returns terminal builds newest-first across jobs, capped by limit")
    func recentBuildsSortAndLimit() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let a = try await Self.createNoOpJob(app)
            let b = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/api/jobs/\(a)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: a, number: 1)
            try await app.testing().test(.POST, "/api/jobs/\(b)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: b, number: 1)

            try await app.testing().test(.GET, "/api/builds/recent") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder(usingISO8601: ()).decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.limit == 20)
                #expect(d.builds.count == 2)
                // Newest first.
                let first = d.builds[0]
                let second = d.builds[1]
                if let f = first.endedAt, let s = second.endedAt {
                    #expect(f >= s)
                }
                #expect(first.status == "passed")
                #expect(second.status == "passed")
                let ids = Set(d.builds.map { $0.jobID })
                #expect(ids == Set([a, b]))
            }

            try await app.testing().test(.GET, "/api/builds/recent?limit=1") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder(usingISO8601: ()).decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.limit == 1)
                #expect(d.builds.count == 1)
            }
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 29: status / jobID filters on /api/builds/recent
    // ──────────────────────────────────────────────────────────────

    @Test("GET /api/builds/recent rejects non-terminal status with 400 (Phase 29)")
    func recentBuildsBadStatus() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            for s in ["queued", "running", "bogus"] {
                try await app.testing().test(.GET, "/api/builds/recent?status=\(s)") { res in
                    #expect(res.status == .badRequest)
                }
            }
        }
    }

    @Test("GET /api/builds/recent?status=passed echoes filter and excludes other statuses (Phase 29)")
    func recentBuildsStatusFilter() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)

            try await app.testing().test(.GET, "/api/builds/recent?status=passed") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder(usingISO8601: ()).decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.statusFilter == "passed")
                #expect(d.builds.allSatisfy { $0.status == "passed" })
                #expect(d.builds.count >= 1)
            }
            try await app.testing().test(.GET, "/api/builds/recent?status=failed") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder(usingISO8601: ()).decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.statusFilter == "failed")
                #expect(d.builds.isEmpty)
            }
        }
    }

    @Test("GET /api/builds/recent?jobID=… restricts to a single job (Phase 29)")
    func recentBuildsJobIDFilter() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let a = try await Self.createNoOpJob(app)
            let b = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/api/jobs/\(a)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: a, number: 1)
            try await app.testing().test(.POST, "/api/jobs/\(b)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: b, number: 1)

            try await app.testing().test(.GET, "/api/builds/recent?jobID=\(a)") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder(usingISO8601: ()).decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.jobIDFilter == a)
                #expect(d.builds.allSatisfy { $0.jobID == a })
                #expect(d.builds.count >= 1)
            }
            // Unknown jobID → empty list, NOT 404.
            try await app.testing().test(.GET, "/api/builds/recent?jobID=does-not-exist") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder(usingISO8601: ()).decode(
                    RecentBuildsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.jobIDFilter == "does-not-exist")
                #expect(d.builds.isEmpty)
            }
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 30: GET /api/stats aggregate JSON summary
    // ──────────────────────────────────────────────────────────────

    @Test("GET /api/stats returns zeros and a stable status label set on a fresh store (Phase 30)")
    func statsEmpty() async throws {
        try await Self.withConfiguredApp { app, _, _ in
            try await app.testing().test(.GET, "/api/stats") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder().decode(
                    StatsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.version == SwiftCIApp.version)
                #expect(d.jobs == 0)
                #expect(d.queueDepth == 0)
                #expect(d.agentsIdle == 0)
                #expect(d.buildsByJobStatus.isEmpty)
                for s in ["queued", "running", "passed", "failed", "canceled"] {
                    #expect(d.buildsByStatus[s] == 0)
                }
                #expect(d.processStartTimeUnixSeconds > 1_600_000_000)
            }
        }
    }

    @Test("GET /api/stats reports per-job and aggregate counts after a build (Phase 30)")
    func statsAfterBuild() async throws {
        try await Self.withConfiguredApp { app, store, _ in
            let jobID = try await Self.createNoOpJob(app)
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger") { res in
                #expect(res.status == .accepted)
            }
            _ = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)

            try await app.testing().test(.GET, "/api/stats") { res in
                #expect(res.status == .ok)
                let d = try JSONDecoder().decode(
                    StatsResponse.self,
                    from: Data(res.body.string.utf8))
                #expect(d.jobs == 1)
                #expect((d.buildsByStatus["passed"] ?? 0) >= 1)
                let perJob = d.buildsByJobStatus[jobID] ?? [:]
                #expect((perJob["passed"] ?? 0) >= 1)
            }
        }
    }
}

private extension JSONDecoder {
    convenience init(usingISO8601 _: Void) {
        self.init()
        self.dateDecodingStrategy = .iso8601
    }
}
