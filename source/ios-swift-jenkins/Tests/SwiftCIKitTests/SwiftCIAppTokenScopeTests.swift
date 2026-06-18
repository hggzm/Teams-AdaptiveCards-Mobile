import Foundation
import Testing
import Vapor
import VaporTesting
@testable import SwiftCIKit

/// Phase 35 — RBAC + API token route tests.
@Suite("SwiftCIApp scopes & token routes", .serialized)
struct SwiftCIAppTokenScopeTests {

    private static func bearer(_ secret: String) -> HTTPHeaders {
        HTTPHeaders([("Authorization", "Bearer \(secret)")])
    }

    private static let echoYAML = """
    name: Scopes
    steps:
      - name: Hi
        run: echo hi
    """

    @Test("legacy adminToken still authorizes POST /api/jobs (back-compat)")
    func legacyAdminBackCompat() async throws {
        try await SwiftCIAppTests.withConfiguredApp(
            adminToken: "legacy-master"
        ) { app, _, _ in
            var buf = ByteBuffer(); buf.writeString(Self.echoYAML)
            try await app.testing().test(.POST, "/api/jobs",
                headers: Self.bearer("legacy-master"), body: buf) { res in
                #expect(res.status == .created)
            }
            // wrong token rejected
            var buf2 = ByteBuffer(); buf2.writeString(Self.echoYAML)
            try await app.testing().test(.POST, "/api/jobs",
                headers: Self.bearer("nope"), body: buf2) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("trigger-scoped token CAN trigger but CANNOT create a job")
    func triggerScopedCannotCreate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-scope-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenStore = APITokenStore(directory: dir)
        let admin = try await tokenStore.create(name: "admin", scopes: [.admin])
        let trig  = try await tokenStore.create(name: "ci-bot", scopes: [.trigger])

        try await SwiftCIAppTests.withConfiguredApp(
            tokenStore: tokenStore
        ) { app, _, _ in
            // 1. Admin creates a job.
            var buf = ByteBuffer(); buf.writeString(Self.echoYAML)
            var jobID = ""
            try await app.testing().test(.POST, "/api/jobs",
                headers: Self.bearer(admin.secret), body: buf) { res in
                #expect(res.status == .created)
                struct P: Codable { let id: String; let name: String }
                jobID = try JSONDecoder().decode(P.self,
                    from: Data(res.body.string.utf8)).id
            }
            // 2. trigger-scope token CAN trigger.
            try await app.testing().test(.POST, "/api/jobs/\(jobID)/trigger",
                headers: Self.bearer(trig.secret)) { res in
                #expect(res.status == .accepted)
            }
            // 3. trigger-scope token CANNOT create a job.
            var buf2 = ByteBuffer(); buf2.writeString(Self.echoYAML)
            try await app.testing().test(.POST, "/api/jobs",
                headers: Self.bearer(trig.secret), body: buf2) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("missing Authorization header is rejected when tokenStore is configured")
    func missingAuthRejected() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-scope-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenStore = APITokenStore(directory: dir)
        _ = try await tokenStore.create(name: "admin", scopes: [.admin])

        try await SwiftCIAppTests.withConfiguredApp(
            tokenStore: tokenStore
        ) { app, _, _ in
            var buf = ByteBuffer(); buf.writeString(Self.echoYAML)
            try await app.testing().test(.POST, "/api/jobs", body: buf) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("POST /api/tokens mints a token, GET lists it, DELETE removes it")
    func tokenMgmtRoutes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-scope-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenStore = APITokenStore(directory: dir)
        let admin = try await tokenStore.create(name: "admin", scopes: [.admin])

        try await SwiftCIAppTests.withConfiguredApp(
            tokenStore: tokenStore
        ) { app, _, _ in
            // mint via API
            var body = ByteBuffer()
            body.writeString(#"{"name":"bot","scopes":["trigger"]}"#)
            var mintedID = ""
            var mintedSecret = ""
            try await app.testing().test(.POST, "/api/tokens",
                headers: Self.bearer(admin.secret), body: body) { res in
                #expect(res.status == .created)
                struct R: Codable {
                    let id: String; let name: String; let secret: String
                    let scopes: [String]
                }
                let r = try JSONDecoder().decode(R.self,
                    from: Data(res.body.string.utf8))
                #expect(r.name == "bot")
                #expect(r.scopes == ["trigger"])
                #expect(r.secret.count == 32)
                mintedID = r.id
                mintedSecret = r.secret
            }
            // minted token can trigger nothing yet (no job), but admin
            // listing should include both admin + bot
            try await app.testing().test(.GET, "/api/tokens",
                headers: Self.bearer(admin.secret)) { res in
                #expect(res.status == .ok)
                struct ListResp: Codable {
                    struct Item: Codable {
                        let id: String; let name: String; let scopes: [String]
                    }
                    let tokens: [Item]
                }
                let parsed = try JSONDecoder().decode(ListResp.self,
                    from: Data(res.body.string.utf8))
                #expect(parsed.tokens.contains(where: { $0.id == mintedID }))
                // list MUST NOT expose secrets
                #expect(!res.body.string.contains(mintedSecret))
            }
            // non-admin can't list
            try await app.testing().test(.GET, "/api/tokens",
                headers: Self.bearer(mintedSecret)) { res in
                #expect(res.status == .unauthorized)
            }
            // delete
            try await app.testing().test(.DELETE, "/api/tokens/\(mintedID)",
                headers: Self.bearer(admin.secret)) { res in
                #expect(res.status == .noContent)
            }
            // re-delete 404s
            try await app.testing().test(.DELETE, "/api/tokens/\(mintedID)",
                headers: Self.bearer(admin.secret)) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/tokens with bad scope name → 400")
    func tokenMintRejectsBadScope() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-scope-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenStore = APITokenStore(directory: dir)
        let admin = try await tokenStore.create(name: "admin", scopes: [.admin])

        try await SwiftCIAppTests.withConfiguredApp(
            tokenStore: tokenStore
        ) { app, _, _ in
            var body = ByteBuffer()
            body.writeString(#"{"name":"bot","scopes":["bogus"]}"#)
            try await app.testing().test(.POST, "/api/tokens",
                headers: Self.bearer(admin.secret), body: body) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("/api/tokens returns 503 when no tokenStore is configured")
    func tokenRoutes503WithoutStore() async throws {
        try await SwiftCIAppTests.withConfiguredApp(
            adminToken: "legacy"
        ) { app, _, _ in
            try await app.testing().test(.GET, "/api/tokens",
                headers: Self.bearer("legacy")) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }
}
