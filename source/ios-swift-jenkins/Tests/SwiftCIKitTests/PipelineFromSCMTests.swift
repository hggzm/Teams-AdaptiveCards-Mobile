import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Phase 34: pipeline-from-SCM", .serialized)
struct PipelineFromSCMTests {

    // ──────────────────────────────────────────────────────────
    // Schema: scm decode/encode round-trip and validation rules.
    // ──────────────────────────────────────────────────────────

    @Test("Pipeline with `scm:` and no `steps:` decodes to empty steps")
    func scmAllowsMissingSteps() throws {
        let yaml = """
        name: FromSCM
        scm:
          git:
            url: https://example.com/foo.git
            ref: develop
          jenkinsfile: ci/Jenkinsfile
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.scm?.git.url == "https://example.com/foo.git")
        #expect(p.scm?.git.ref == "develop")
        #expect(p.scm?.jenkinsfile == "ci/Jenkinsfile")
        #expect(p.steps.isEmpty)
    }

    @Test("Pipeline without `scm:` requires non-empty `steps:`")
    func nonScmRequiresSteps() {
        let yaml = """
        name: NoSteps
        steps: []
        """
        #expect(throws: DecodingError.self) {
            _ = try Pipeline.decode(yaml: yaml)
        }
    }

    @Test("Pipeline with both `scm:` and `agentLabels:` is rejected")
    func scmAndAgentLabelsConflict() {
        let yaml = """
        name: Conflict
        scm:
          git:
            url: https://example.com/foo.git
        agentLabels: [linux]
        """
        #expect(throws: DecodingError.self) {
            _ = try Pipeline.decode(yaml: yaml)
        }
    }

    @Test("Pipeline.SCMConfig defaults: ref=main, jenkinsfile=Jenkinsfile")
    func scmDefaults() throws {
        let yaml = """
        name: Defaults
        scm:
          git:
            url: https://example.com/foo.git
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.scm?.git.ref == "main")
        #expect(p.scm?.jenkinsfile == "Jenkinsfile")
    }

    @Test("Pipeline.SCMConfig round-trips through YAML")
    func scmRoundTrip() throws {
        let original = Pipeline(
            name: "X", steps: [],
            scm: .init(git: .init(url: "https://example.com/a.git", ref: "develop"),
                       jenkinsfile: "ci/Jenkinsfile"))
        let yaml = try original.encodeYAML()
        let decoded = try Pipeline.decode(yaml: yaml)
        #expect(decoded == original)
    }

    // ──────────────────────────────────────────────────────────
    // Behavior: BuildExecutor clones a local file:// repo and
    // executes the imported Jenkinsfile.
    //
    // These tests require `git` on PATH. They are skipped (with a
    // warning Issue) on hosts that don't have it.
    // ──────────────────────────────────────────────────────────

    @Test("BuildExecutor clones a local repo and runs imported steps")
    func clonesAndRunsImportedJenkinsfile() async throws {
        guard gitOnPath() else {
            Issue.record("git not on PATH; skipping Phase 34 SCM smoke test")
            return
        }

        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        // Build a real git repo on disk to clone from.
        let repoSrc = temp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: repoSrc, withIntermediateDirectories: true)
        let jfBody = """
        pipeline {
            agent any
            stages {
                stage('FromJenkinsfile') {
                    steps {
                        sh 'echo PHASE34-MARKER-OK'
                    }
                }
            }
        }
        """
        try jfBody.write(to: repoSrc.appendingPathComponent("Jenkinsfile"),
                         atomically: true, encoding: .utf8)
        try shellInDir(repoSrc, "git", ["init", "-q"])
        try shellInDir(repoSrc, "git", ["config", "user.email", "test@example.com"])
        try shellInDir(repoSrc, "git", ["config", "user.name", "Test"])
        try shellInDir(repoSrc, "git", ["add", "Jenkinsfile"])
        try shellInDir(repoSrc, "git", ["commit", "-q", "-m", "init"])
        // Normalize branch name to `main` regardless of the host
        // git's `init.defaultBranch` setting (older Windows installs
        // still default to `master`, and `git init -b main` is not
        // supported pre-2.28).
        try shellInDir(repoSrc, "git", ["branch", "-M", "main"])

        // Controller-side pipeline pointing at the local repo.
        let storeRoot = temp.appendingPathComponent("store", isDirectory: true)
        let store = JobStore(root: storeRoot)
        let url = repoSrc.absoluteString  // file:// URL
        let pipeline = Pipeline(
            name: "Phase34",
            steps: [],
            scm: .init(git: .init(url: url, ref: "main")))
        let jobID = try store.createJob(from: pipeline)

        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await waitTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()

        #expect(final.status == .passed, "expected passed; got \(final.status)")
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("=== scm: cloning"))
        #expect(log.contains("=== scm: pipeline loaded from Jenkinsfile (1 step) ==="))
        #expect(log.contains("PHASE34-MARKER-OK"))
    }

    @Test("BuildExecutor fails the build when the clone url is invalid")
    func failsOnInvalidCloneURL() async throws {
        guard gitOnPath() else {
            Issue.record("git not on PATH; skipping Phase 34 SCM smoke test")
            return
        }
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let storeRoot = temp.appendingPathComponent("store", isDirectory: true)
        let store = JobStore(root: storeRoot)
        let bogus = temp.appendingPathComponent("does-not-exist").absoluteString
        let pipeline = Pipeline(
            name: "Phase34Bad",
            steps: [],
            scm: .init(git: .init(url: bogus, ref: "main")))
        let jobID = try store.createJob(from: pipeline)
        let executor = BuildExecutor(store: store)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)
        let final = try await waitTerminal(store: store, jobID: jobID, number: 1)
        await executor.stop()
        #expect(final.status == .failed)
        let log = try store.readLog(jobID: jobID, number: 1)
        #expect(log.contains("scm: git clone failed") || log.contains("scm: cloneFailed"))
    }

    // ──────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-scm-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gitOnPath() -> Bool {
        #if os(Windows)
        let exe = "git.exe"
        let sep: Character = ";"
        #else
        let exe = "git"
        let sep: Character = ":"
        #endif
        guard let p = ProcessInfo.processInfo.environment["PATH"]
              ?? ProcessInfo.processInfo.environment["Path"] else { return false }
        for d in p.split(separator: sep) {
            if FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(d))
                    .appendingPathComponent(exe).path) {
                return true
            }
        }
        return false
    }

    private func shellInDir(_ dir: URL, _ exe: String, _ args: [String]) throws {
        guard let exeURL = resolveOnPath(exe) else {
            throw NSError(domain: "shellInDir", code: 127,
                userInfo: [NSLocalizedDescriptionKey: "\(exe) not found on PATH"])
        }
        let p = Foundation.Process()
        p.executableURL = exeURL
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw NSError(domain: "shellInDir", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "\(exe) \(args.joined(separator: " ")) exited \(p.terminationStatus): \(out)"])
        }
    }

    private func resolveOnPath(_ exe: String) -> URL? {
        #if os(Windows)
        let candidates = [exe, exe + ".exe"]
        let sep: Character = ";"
        #else
        let candidates = [exe]
        let sep: Character = ":"
        #endif
        guard let p = ProcessInfo.processInfo.environment["PATH"]
              ?? ProcessInfo.processInfo.environment["Path"] else { return nil }
        for d in p.split(separator: sep) {
            for c in candidates {
                let url = URL(fileURLWithPath: String(d)).appendingPathComponent(c)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private func waitTerminal(
        store: JobStore, jobID: String, number: Int,
        timeout: Duration = .seconds(30)
    ) async throws -> Build {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let b = try? store.loadBuild(jobID: jobID, number: number),
               b.status.isTerminal {
                return b
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw NSError(domain: "waitTerminal", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timeout waiting for build to terminate"])
    }
}
