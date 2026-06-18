import Foundation
import Testing
@testable import SwiftCIKit

@Suite("APITokenStore (Phase 35)", .serialized)
struct APITokenStoreTests {

    private static func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-tokenstore-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
            withIntermediateDirectories: true)
        return url
    }

    @Test("create persists a token and list returns it")
    func createAndList() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APITokenStore(directory: dir)

        let t = try await store.create(name: "ci-bot",
                                       scopes: [.trigger])
        #expect(t.name == "ci-bot")
        #expect(t.scopes == [.trigger])
        #expect(t.secret.count == 32)
        #expect(t.id.count == 8)

        let listed = try await store.list()
        #expect(listed.count == 1)
        #expect(listed[0].id == t.id)
        #expect(listed[0].secret == t.secret)
    }

    @Test("tokens.json round-trips across store instances")
    func roundTripsAcrossInstances() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = APITokenStore(directory: dir)
        let minted = try await a.create(name: "admin-1",
                                        scopes: [.admin, .read])

        let b = APITokenStore(directory: dir)
        let listed = try await b.list()
        #expect(listed.count == 1)
        #expect(listed[0].secret == minted.secret)
        #expect(Set(listed[0].scopes) == Set([.admin, .read]))
    }

    @Test("lookup returns the matching token by secret")
    func lookupBySecret() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APITokenStore(directory: dir)
        let t = try await store.create(name: "x", scopes: [.read])

        let hit = try await store.lookup(secret: t.secret)
        #expect(hit?.id == t.id)

        let miss = try await store.lookup(secret: "0000")
        #expect(miss == nil)
    }

    @Test("duplicate names are rejected")
    func duplicateNameRejected() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APITokenStore(directory: dir)
        _ = try await store.create(name: "dup", scopes: [.trigger])
        do {
            _ = try await store.create(name: "dup", scopes: [.trigger])
            Issue.record("expected duplicateName error")
        } catch APITokenStore.CreateError.duplicateName(let n) {
            #expect(n == "dup")
        }
    }

    @Test("empty name / empty scopes are rejected")
    func validationRejectsEmpties() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APITokenStore(directory: dir)
        do {
            _ = try await store.create(name: "  ", scopes: [.read])
            Issue.record("expected nameEmpty")
        } catch APITokenStore.CreateError.nameEmpty {}
        do {
            _ = try await store.create(name: "x", scopes: [])
            Issue.record("expected scopesEmpty")
        } catch APITokenStore.CreateError.scopesEmpty {}
    }

    @Test("delete removes a token; deleting unknown 404s")
    func deleteFlow() async throws {
        let dir = Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APITokenStore(directory: dir)
        let t = try await store.create(name: "kill-me", scopes: [.read])
        try await store.delete(id: t.id)
        let listed = try await store.list()
        #expect(listed.isEmpty)

        do {
            try await store.delete(id: "nope0000")
            Issue.record("expected notFound")
        } catch APITokenStore.DeleteError.notFound(let id) {
            #expect(id == "nope0000")
        }
    }

    @Test("admin scope satisfies any required scope")
    func adminSatisfiesAll() {
        #expect(APITokenStore.satisfies(scopes: [.admin], required: .read))
        #expect(APITokenStore.satisfies(scopes: [.admin], required: .trigger))
        #expect(APITokenStore.satisfies(scopes: [.admin], required: .admin))
        #expect(APITokenStore.satisfies(scopes: [.trigger], required: .trigger))
        #expect(!APITokenStore.satisfies(scopes: [.trigger], required: .admin))
        #expect(!APITokenStore.satisfies(scopes: [.read], required: .trigger))
    }
}
