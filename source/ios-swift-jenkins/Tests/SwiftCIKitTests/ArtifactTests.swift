import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Artifacts (Phase 7)", .serialized)
struct ArtifactTests {
    static func makeTempStore() -> JobStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-artifact-tests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("collectArtifact copies a workspace file into <build>/artifacts/")
    func collectsFile() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Manual", steps: [.init(name: "x", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        let ws = try store.provisionWorkspace(jobID: jobID, number: 1)
        let src = ws.appendingPathComponent("hello.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)

        let url = try store.collectArtifact(jobID: jobID, number: 1, relativePath: "hello.txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "hello.txt")

        let names = try store.listArtifacts(jobID: jobID, number: 1)
        #expect(names == ["hello.txt"])
    }

    @Test("collectArtifact copies a directory recursively (flat-named at destination)")
    func collectsDirectory() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Manual", steps: [.init(name: "x", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        let ws = try store.provisionWorkspace(jobID: jobID, number: 1)
        let dir = ws.appendingPathComponent("payload", isDirectory: true)
        // Windows AV / indexer can briefly lock just-created dirs and
        // the files under them. Mirror the executor's retry policy
        // for the test's whole setup so the suite is stable.
        try AtomicIO.withRetry(attempts: 16) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // NOT atomic — on Windows MSVC Foundation, atomic writes
            // leave a `.dat.nosync<hex>` temp file in the parent dir
            // for a brief window. If `collectArtifact` happens to fire
            // (or `copyItem` runs) inside that window, the tempfile
            // gets copied alongside the real files and the test's
            // contents-equality assertion fails. Non-atomic writes are
            // fine for fixture data we're about to discard.
            try Data("a".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data("b".utf8).write(to: dir.appendingPathComponent("b.txt"))
        }

        let url = try store.collectArtifact(jobID: jobID, number: 1, relativePath: "payload")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        #expect(contents == ["a.txt", "b.txt"])
    }

    @Test("collectArtifact rejects path-traversal (../ outside workspace)")
    func rejectsTraversal() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Manual", steps: [.init(name: "x", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        _ = try store.provisionWorkspace(jobID: jobID, number: 1)
        #expect(throws: ArtifactError.self) {
            try store.collectArtifact(
                jobID: jobID, number: 1, relativePath: "../../etc/passwd")
        }
    }

    @Test("collectArtifact throws .missing for a non-existent source")
    func missingSource() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Manual", steps: [.init(name: "x", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        _ = try store.provisionWorkspace(jobID: jobID, number: 1)
        #expect(throws: ArtifactError.self) {
            try store.collectArtifact(
                jobID: jobID, number: 1, relativePath: "does-not-exist.txt")
        }
    }

    @Test("artifactURL returns nil for unknown artifact + escape attempts")
    func artifactURLSafety() throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Manual", steps: [.init(name: "x", run: "true")]))
        _ = try store.createBuild(jobID: jobID)
        _ = try store.provisionWorkspace(jobID: jobID, number: 1)
        // Unknown name → nil
        #expect(store.artifactURL(jobID: jobID, number: 1, name: "nope.txt") == nil)
        // Escape attempt → nil even if the file exists somewhere on disk
        #expect(store.artifactURL(jobID: jobID, number: 1, name: "../config.yaml") == nil)
    }

    @Test("BuildExecutor collects step.artifacts after a passing step")
    func executorCollectsArtifacts() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "WithArtifacts",
            steps: [
                .init(name: "MakeFile", run: {
                    #if os(Windows)
                    return "echo content > out.txt"
                    #else
                    return "echo content > out.txt"
                    #endif
                }(), artifacts: ["out.txt"])
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()

        #expect(final.status == .passed)
        let names = try store.listArtifacts(jobID: jobID, number: 1)
        #expect(names == ["out.txt"])
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("artifact: out.txt"))
    }

    @Test("artifacts are NOT collected when a step fails")
    func notCollectedOnFailure() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "Fails",
            steps: [
                .init(name: "Crash", run: "exit 5", artifacts: ["out.txt"])
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()

        #expect(final.status == .failed)
        let names = try store.listArtifacts(jobID: jobID, number: 1)
        #expect(names.isEmpty)
    }

    @Test("missing declared artifact logs failure but doesn't fail the build")
    func missingArtifactLogged() async throws {
        let store = Self.makeTempStore()
        defer { Self.cleanUp(store) }
        let jobID = try store.createJob(from: Pipeline(
            name: "BestEffort",
            steps: [
                .init(name: "OK", run: "echo ok",
                      artifacts: ["never-created.txt"])
            ]
        ))
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await Self.waitForTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()

        #expect(final.status == .passed)
        let names = try store.listArtifacts(jobID: jobID, number: 1)
        #expect(names.isEmpty)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("FAILED to collect"))
    }
}

@Suite("Pipeline schema (Phase 7 artifacts)")
struct PipelineSchemaPhase7Tests {
    @Test("artifacts: list parses from YAML")
    func decodeArtifacts() throws {
        let yaml = """
        name: WithArtifacts
        steps:
          - name: Build
            run: swift build
            artifacts:
              - build/x.exe
              - build/manifest.json
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.steps[0].artifacts == ["build/x.exe", "build/manifest.json"])
    }

    @Test("missing artifacts defaults to empty")
    func decodeWithoutArtifacts() throws {
        let yaml = """
        name: NoArt
        steps:
          - name: Build
            run: swift build
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.steps[0].artifacts.isEmpty)
    }

    @Test("encode omits empty artifacts; includes non-empty")
    func encodingShape() throws {
        let empty = Pipeline(name: "x", steps: [.init(name: "s", run: "true")])
        let emptyYAML = try empty.encodeYAML()
        #expect(!emptyYAML.contains("artifacts"))

        let withArt = Pipeline(name: "x", steps: [
            .init(name: "s", run: "true", artifacts: ["a.txt"])
        ])
        let withArtYAML = try withArt.encodeYAML()
        #expect(withArtYAML.contains("artifacts"))
        #expect(withArtYAML.contains("a.txt"))
    }
}
