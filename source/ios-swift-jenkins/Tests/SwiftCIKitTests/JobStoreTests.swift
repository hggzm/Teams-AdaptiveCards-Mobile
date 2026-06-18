import Foundation
import Testing
@testable import SwiftCIKit

@Suite("JobStore")
struct JobStoreTests {
    /// Each test gets its own temp dir to avoid cross-test pollution.
    static func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("createJob persists config.yaml and returns a slugged id")
    func createJob() throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)

        let pipeline = Pipeline(
            name: "Build & Test",
            steps: [.init(name: "Compile", run: "swift build")]
        )
        let id = try store.createJob(from: pipeline)

        #expect(id.hasPrefix("build-test-"))
        #expect(id.count == "build-test-".count + 8)

        let configURL = root
            .appendingPathComponent("jobs")
            .appendingPathComponent(id)
            .appendingPathComponent("config.yaml")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        let buildsDir = root
            .appendingPathComponent("jobs")
            .appendingPathComponent(id)
            .appendingPathComponent("builds")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: buildsDir.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test("loadJob returns the same pipeline that was created")
    func roundTrip() throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)

        let original = Pipeline(
            name: "RoundTrip",
            steps: [
                .init(name: "One", run: "echo one"),
                .init(name: "Two", run: "echo two"),
            ]
        )
        let id = try store.createJob(from: original)
        let loaded = try store.loadJob(id: id)
        #expect(loaded == original)
    }

    @Test("loadJob returns nil for an unknown id")
    func loadMissing() throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)
        let loaded = try store.loadJob(id: "does-not-exist-00000000")
        #expect(loaded == nil)
    }

    @Test("listJobIDs returns persisted ids sorted")
    func listJobs() throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)

        let a = try store.createJob(from: Pipeline(name: "Alpha", steps: [.init(name: "s", run: "true")]))
        let b = try store.createJob(from: Pipeline(name: "Bravo", steps: [.init(name: "s", run: "true")]))
        let c = try store.createJob(from: Pipeline(name: "Charlie", steps: [.init(name: "s", run: "true")]))

        let ids = try store.listJobIDs()
        #expect(Set(ids) == Set([a, b, c]))
        #expect(ids == ids.sorted())
    }

    @Test("listJobIDs returns empty when root does not exist")
    func listEmpty() throws {
        let root = Self.makeTempRoot()
            .appendingPathComponent("never-created", isDirectory: true)
        let store = JobStore(root: root)
        let ids = try store.listJobIDs()
        #expect(ids.isEmpty)
    }

    @Test("makeID slugifies names with punctuation, unicode, and uppercase")
    func slugify() {
        let id1 = JobStore.makeID(for: "Build & Test!")
        #expect(id1.hasPrefix("build-test-"))

        let id2 = JobStore.makeID(for: "   trailing   spaces   ")
        #expect(id2.hasPrefix("trailing-spaces-"))

        let id3 = JobStore.makeID(for: "")
        #expect(id3.hasPrefix("job-"))

        // ASCII-only check: hyphen, lowercase letters, digits.
        for ch in id1 {
            #expect(ch.isASCII)
            #expect(ch == "-" || ch.isLowercase || ch.isNumber)
        }
    }
}
