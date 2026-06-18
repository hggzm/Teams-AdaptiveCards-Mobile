import Foundation
import Testing
@testable import SwiftCIKit

@Suite("CredentialStore (Phase 37)", .serialized)
struct CredentialStoreTests {

    private static func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-credstore-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
            withIntermediateDirectories: true)
        return url
    }

    @Test("create persists a credential and list returns it")
    func createAndList() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CredentialStore(directory: dir)

        let c = try await store.create(id: "deploy-key",
                                       description: "prod deploy",
                                       value: "s3cr3t")
        #expect(c.id == "deploy-key")
        #expect(c.kind == .string)
        #expect(c.value == "s3cr3t")
        #expect(c.description == "prod deploy")

        let listed = try await store.list()
        #expect(listed.count == 1)
        #expect(listed[0].id == "deploy-key")
    }

    @Test("credentials.json round-trips across store instances")
    func roundTripsAcrossInstances() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = CredentialStore(directory: dir)
        _ = try await a.create(id: "tok", value: "abcdef")

        let b = CredentialStore(directory: dir)
        let listed = try await b.list()
        #expect(listed.count == 1)
        #expect(listed[0].id == "tok")
        #expect(listed[0].value == "abcdef")
    }

    @Test("lookup returns the matching credential by id")
    func lookupById() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CredentialStore(directory: dir)
        _ = try await store.create(id: "a", value: "1")
        _ = try await store.create(id: "b", value: "2")

        let hit = try await store.lookup(id: "b")
        #expect(hit?.value == "2")

        let miss = try await store.lookup(id: "nope")
        #expect(miss == nil)
    }

    @Test("duplicate ids are rejected")
    func duplicateIdRejected() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CredentialStore(directory: dir)
        _ = try await store.create(id: "dup", value: "x")
        do {
            _ = try await store.create(id: "dup", value: "y")
            Issue.record("expected duplicateID")
        } catch CredentialStore.CreateError.duplicateID(let id) {
            #expect(id == "dup")
        }
    }

    @Test("empty id / empty value are rejected")
    func validationRejectsEmpties() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CredentialStore(directory: dir)
        do {
            _ = try await store.create(id: "  ", value: "x")
            Issue.record("expected idEmpty")
        } catch CredentialStore.CreateError.idEmpty {}
        do {
            _ = try await store.create(id: "ok", value: "")
            Issue.record("expected valueEmpty")
        } catch CredentialStore.CreateError.valueEmpty {}
    }

    @Test("delete removes a credential; deleting unknown 404s")
    func deleteFlow() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CredentialStore(directory: dir)
        _ = try await store.create(id: "kill-me", value: "x")
        try await store.delete(id: "kill-me")
        let listed = try await store.list()
        #expect(listed.isEmpty)

        do {
            try await store.delete(id: "nope")
            Issue.record("expected notFound")
        } catch CredentialStore.DeleteError.notFound(let id) {
            #expect(id == "nope")
        }
    }
}
