import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Agent protocol (Phase 14)")
struct AgentProtocolTests {
    @Test("register round-trips via JSON")
    func registerRoundTrip() throws {
        let original = AgentMessage.register(.init(
            name: "agent-1",
            labels: ["windows", "swift-6.3"],
            agentVersion: "0.1.0"))
        let json = try original.encodeJSON()
        let decoded = try AgentMessage.decode(json: json)
        #expect(decoded == original)
    }

    @Test("runBuild round-trips with nested Pipeline")
    func runBuildRoundTrip() throws {
        let pipeline = Pipeline(
            name: "RemoteEcho",
            steps: [.init(name: "Hi", run: "echo hi",
                          env: ["A": "1"],
                          artifacts: ["out.txt"])],
            notify: [.init(url: "https://h.example.com/", on: .failed)],
            retention: .init(maxBuilds: 7),
            triggers: ["downstream-1"]
        )
        let original = AgentMessage.runBuild(.init(
            buildID: "j#5", jobID: "j", number: 5,
            pipeline: pipeline,
            env: ["SWIFTCI_JOB_ID": "j", "SWIFTCI_BUILD_NUMBER": "5"]))
        let json = try original.encodeJSON()
        let decoded = try AgentMessage.decode(json: json)
        #expect(decoded == original)
    }

    @Test("log round-trips and preserves UTF-8")
    func logRoundTrip() throws {
        // Embedded UTF-8 + control chars (\n, \t) round-trip cleanly.
        let msg = AgentMessage.log(.init(
            buildID: "j#1",
            chunk: "line one\nline two\t\u{1F600}\n"))
        let json = try msg.encodeJSON()
        let decoded = try AgentMessage.decode(json: json)
        #expect(decoded == msg)
    }

    @Test("buildFinished round-trips for every status")
    func buildFinishedAllStatuses() throws {
        for status in [BuildStatus.passed, .failed, .canceled] {
            let msg = AgentMessage.buildFinished(.init(
                buildID: "j#1", status: status, exitCode: 0))
            let json = try msg.encodeJSON()
            let decoded = try AgentMessage.decode(json: json)
            #expect(decoded == msg)
        }
    }

    @Test("unknown message type throws DecodingError")
    func unknownTypeThrows() {
        let bad = #"{"type":"bogus","payload":{}}"#
        #expect(throws: DecodingError.self) {
            _ = try AgentMessage.decode(json: bad)
        }
    }

    @Test("makeBuildID is jobID#number")
    func buildIDFormat() {
        #expect(makeBuildID(jobID: "job-abc", number: 42) == "job-abc#42")
    }

    @Test("artifact round-trips with base64 payload")
    func artifactRoundTrip() throws {
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0xFE, 0xFF, 0x7F, 0x80]
        let b64 = Data(bytes).base64EncodedString()
        let msg = AgentMessage.artifact(.init(
            buildID: "j#7", name: "out.bin", data: b64))
        let json = try msg.encodeJSON()
        let decoded = try AgentMessage.decode(json: json)
        #expect(decoded == msg)
        if case .artifact(let p) = decoded {
            let roundTripped = Data(base64Encoded: p.data)
            #expect(roundTripped == Data(bytes))
        }
    }
}

@Suite("JobStore.isSafeArtifactName")
struct ArtifactNameGuardTests {
    @Test("accepts ordinary names")
    func goodNames() {
        for n in ["out.txt", "report.html", "a-b_c.1.2.zip", "x", "ABC.txt"] {
            #expect(JobStore.isSafeArtifactName(n), "\(n) should be safe")
        }
    }

    @Test("rejects path separators and traversal")
    func badNames() {
        for n in ["../etc/passwd", "a/b.txt", "a\\b.txt", "c:\\evil.txt",
                  "..", ".", ".hidden", "", " leading-space",
                  "with\0null", "with*glob"] {
            #expect(!JobStore.isSafeArtifactName(n), "\(n) should be rejected")
        }
    }

    @Test("rejects overlong names (>200 bytes)")
    func tooLong() {
        let n = String(repeating: "a", count: 201)
        #expect(!JobStore.isSafeArtifactName(n))
    }
}
