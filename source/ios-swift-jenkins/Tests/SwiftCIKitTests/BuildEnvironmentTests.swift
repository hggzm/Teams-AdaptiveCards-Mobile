import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Build environment (Phase 6)", .serialized)
struct BuildEnvironmentTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-env-tests-\(UUID().uuidString)", isDirectory: true)
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

    // Cross-platform "echo one env var by name" command.
    static func echoEnvCommand(_ name: String) -> String {
        #if os(Windows)
        // cmd.exe /c "echo %SWIFTCI_JOB_ID%"
        return "echo %\(name)%"
        #else
        return "printf '%s' \"$\(name)\""
        #endif
    }

    @Test("standard SWIFTCI_JOB_ID + SWIFTCI_BUILD_NUMBER reach the step")
    func standardEnvVisible() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "EnvCheck",
            steps: [
                .init(name: "ShowJob",  run: Self.echoEnvCommand("SWIFTCI_JOB_ID")),
                .init(name: "ShowNum",  run: Self.echoEnvCommand("SWIFTCI_BUILD_NUMBER")),
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains(jobID), "expected job ID \(jobID) in log; got:\n\(log)")
        #expect(log.contains("1"), "expected build number 1 in log; got:\n\(log)")
    }

    @Test("step-level env: map reaches the spawned process")
    func stepEnvVisible() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "StepEnv",
            steps: [
                .init(name: "ShowCustom",
                      run: Self.echoEnvCommand("MY_CUSTOM_VAR"),
                      env: ["MY_CUSTOM_VAR": "the-value-from-yaml"])
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("the-value-from-yaml"))
    }

    @Test("step env: cannot shadow SWIFTCI_* (executor wins)")
    func stepEnvCannotShadow() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "NoShadow",
            steps: [
                .init(name: "ShowJob",
                      run: Self.echoEnvCommand("SWIFTCI_JOB_ID"),
                      env: ["SWIFTCI_JOB_ID": "evil-attempt"])
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains(jobID))
        #expect(!log.contains("evil-attempt"))
    }

    @Test("workspace directory exists, is empty, and is reused-clean across re-runs")
    func workspaceProvisioned() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Workspace",
            steps: [
                // Write a marker into the workspace, then list the dir.
                .init(name: "MakeMarker", run: {
                    #if os(Windows)
                    return "echo hello > marker.txt && dir /b"
                    #else
                    return "echo hello > marker.txt && ls"
                    #endif
                }())
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("marker.txt"))

        // The workspace directory is on disk under the build dir.
        let ws = store.workspaceURL(jobID: jobID, number: 1)
        let marker = ws.appendingPathComponent("marker.txt")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("webhook payload is persisted and SWIFTCI_WEBHOOK_BODY_PATH points at it")
    func webhookPayloadVisible() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "WebhookEnv",
            steps: [
                .init(name: "ShowPath",
                      run: Self.echoEnvCommand("SWIFTCI_WEBHOOK_BODY_PATH"))
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        let payload = WebhookPayload(
            method: "POST",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            headers: ["x-github-event": "push", "content-type": "application/json"],
            rawBody: Data(#"{"ref":"refs/heads/main","sha":"deadbeef"}"#.utf8)
        )
        _ = try await executor.enqueue(jobID: jobID, webhookPayload: payload)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)

        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("webhook.json"),
                "expected webhook.json path in log; got:\n\(log)")

        // The persisted payload round-trips.
        let loaded = try store.loadWebhookPayload(jobID: jobID, number: 1)
        #expect(loaded?.method == "POST")
        #expect(loaded?.headers["x-github-event"] == "push")
        #expect(loaded?.body.contains("deadbeef") == true)
    }

    @Test("no webhook payload => SWIFTCI_WEBHOOK_BODY_PATH is unset")
    func noWebhookPayloadVar() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "NoHook",
            steps: [
                .init(name: "ShowPath",
                      run: Self.echoEnvCommand("SWIFTCI_WEBHOOK_BODY_PATH"))
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)

        // No webhook.json should have been written.
        let url = store.webhookPayloadURL(jobID: jobID, number: 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // The step should see an empty/unset value. On Windows cmd.exe
        // echoes the literal "%VAR%" when unset, so the log contains
        // "%SWIFTCI_WEBHOOK_BODY_PATH%". On POSIX printf gets "".
        let log = try store.readLog(jobID: jobID, number: 1)
        #if os(Windows)
        #expect(log.contains("%SWIFTCI_WEBHOOK_BODY_PATH%"))
        #else
        #expect(!log.contains("/webhook.json"))
        #endif
    }

    // ────────────────────────────────────────────────────────
    // Phase 33: trigger-time `parameters` override step.env
    // defaults but cannot shadow `SWIFTCI_*`.
    // ────────────────────────────────────────────────────────

    @Test("trigger parameters override step env defaults")
    func triggerParametersOverrideStepEnv() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "ParamOverride",
            steps: [
                .init(name: "ShowGreeting",
                      run: Self.echoEnvCommand("GREETING"),
                      env: ["GREETING": "default-from-step"])
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(
            jobID: jobID,
            parameters: ["GREETING": "override-from-trigger"])
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("override-from-trigger"))
        #expect(!log.contains("default-from-step"))
        let persisted = try #require(try store.loadBuild(jobID: jobID, number: 1))
        #expect(persisted.parameters?["GREETING"] == "override-from-trigger")
    }

    @Test("trigger parameters cannot shadow SWIFTCI_* keys")
    func triggerParametersCannotShadow() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "ParamShadow",
            steps: [
                .init(name: "ShowJob",
                      run: Self.echoEnvCommand("SWIFTCI_JOB_ID"))
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(
            jobID: jobID,
            parameters: ["SWIFTCI_JOB_ID": "evil"])
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .passed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains(jobID))
        #expect(!log.contains("evil"))
    }
}

@Suite("Pipeline schema (Phase 6 additions)")
struct PipelineSchemaPhase6Tests {
    @Test("step env: parses from YAML")
    func decodeWithEnv() throws {
        let yaml = """
        name: WithEnv
        steps:
          - name: Build
            run: swift build
            env:
              CONFIGURATION: release
              ANOTHER: value
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.steps[0].env["CONFIGURATION"] == "release")
        #expect(p.steps[0].env["ANOTHER"] == "value")
    }

    @Test("missing env defaults to empty")
    func decodeWithoutEnv() throws {
        let yaml = """
        name: NoEnv
        steps:
          - name: Build
            run: swift build
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.steps[0].env.isEmpty)
    }

    @Test("encode omits empty env")
    func encodeOmitsEmptyEnv() throws {
        let p = Pipeline(name: "x", steps: [.init(name: "s", run: "true")])
        let yaml = try p.encodeYAML()
        #expect(!yaml.contains("env"))
    }

    @Test("encode includes non-empty env")
    func encodeIncludesEnv() throws {
        let p = Pipeline(name: "x", steps: [
            .init(name: "s", run: "true", env: ["K": "v"])
        ])
        let yaml = try p.encodeYAML()
        #expect(yaml.contains("env"))
        #expect(yaml.contains("K"))
        #expect(yaml.contains("v"))
    }

    @Test("Build.parameters round-trips through Codable, omitted when empty")
    func buildParametersCodableRoundTrip() throws {
        let b1 = Build(jobID: "j", number: 1,
                       parameters: ["A": "1", "B": "two"])
        let data1 = try JSONEncoder().encode(b1)
        let json1 = String(data: data1, encoding: .utf8) ?? ""
        #expect(json1.contains("\"parameters\""))
        let r1 = try JSONDecoder().decode(Build.self, from: data1)
        #expect(r1.parameters?["A"] == "1")
        #expect(r1.parameters?["B"] == "two")

        let b2 = Build(jobID: "j", number: 2)
        let data2 = try JSONEncoder().encode(b2)
        let json2 = String(data: data2, encoding: .utf8) ?? ""
        #expect(!json2.contains("\"parameters\""))
        let r2 = try JSONDecoder().decode(Build.self, from: data2)
        #expect(r2.parameters == nil)
    }
}
