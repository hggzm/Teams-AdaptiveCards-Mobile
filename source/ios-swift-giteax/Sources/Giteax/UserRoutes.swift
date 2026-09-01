import Foundation
import Vapor

/// Phase 8 wiring: user-management API + HTTP Basic auth on git push.
///
/// Routes (admin-token-gated; the token is sent as `Authorization: Bearer <token>`
/// matching the value of `GITEAX_ADMIN_TOKEN`):
///
///   POST   /api/users           -> create a user
///   GET    /api/users           -> list usernames
///   DELETE /api/users/:name     -> delete a user
///
/// Push gate (replacing Phase 7's bare env-flag check):
///
///   1. Server started without GITEAX_ALLOW_PUSH=1   -> push is fully disabled (403).
///   2. With push allowed AND no users registered   -> push refused with 401 unless
///                                                     GITEAX_ALLOW_ANON_PUSH=1 was
///                                                     also set (then falls back to
///                                                     Phase 7's open behavior).
///   3. With push allowed AND at least one user     -> HTTP Basic auth required;
///                                                     401 on missing/wrong creds.
///
/// Browse and clone (upload-pack) are NEVER auth-gated in this phase --
/// they remain open. That follows Gitea's "anonymous read by default"
/// model for public repos. Per-repo visibility flags are a later phase.
func registerUserRoutes(
    _ app: Application,
    store: UserStore,
    adminToken: String?
) {
    /// Bearer-token middleware over the admin endpoints. Drops the
    /// request with 401 when the token is absent / missing / wrong.
    struct AdminBearer: AsyncMiddleware {
        let expected: String
        func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            guard let raw = req.headers.bearerAuthorization?.token, raw == expected else {
                throw Abort(.unauthorized, reason: "admin token required")
            }
            return try await next.respond(to: req)
        }
    }

    // Always-on health probe so admins can confirm the user store wired up.
    app.get("api", "users-status") { req async throws -> Response in
        let n = await store.count()
        return try jsonResponse(UsersStatusDTO(
            userCount: n,
            adminTokenConfigured: adminToken != nil,
            isEmpty: n == 0
        ))
    }

    // Admin endpoints (gated). If no admin token is configured, these
    // routes return 503 -- not registered, but always 503 so callers
    // get a clear signal.
    guard let adminToken else {
        for path in ["api/users", "api/users/:name"] {
            app.on(.POST,   path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "admin API disabled (set GITEAX_ADMIN_TOKEN to enable)")
            }
            app.on(.DELETE, path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "admin API disabled (set GITEAX_ADMIN_TOKEN to enable)")
            }
        }
        return
    }

    let admin = app.grouped(AdminBearer(expected: adminToken))

    admin.post("api", "users") { req async throws -> Response in
        let body = try req.content.decode(CreateUserDTO.self)
        do {
            let user = try await store.create(
                name: body.name,
                password: body.password,
                isAdmin: body.isAdmin ?? false
            )
            return try jsonResponse(UserDTO(
                name: user.name,
                createdAt: user.createdAt,
                isAdmin: user.isAdmin
            ), status: .created)
        } catch let e as UserStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    admin.get("api", "users") { req async throws -> Response in
        let names = await store.listNames()
        return try jsonResponse(UsersListDTO(count: names.count, users: names))
    }

    admin.delete("api", "users", ":name") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        do {
            try await store.delete(name: name)
            return Response(status: .noContent)
        } catch let e as UserStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
}

/// HTTP Basic auth check for git push. NOT a Vapor middleware -- the
/// gate is invoked explicitly by the receive-pack and info/refs route
/// handlers in `RepoRoutes.swift`, because info/refs is one endpoint
/// shared by upload-pack (open) and receive-pack (auth) services and
/// we have to inspect `?service=` to decide.
///
/// Returns `nil` when the request is authorized (handler should
/// proceed); returns a Response with status 401 + WWW-Authenticate
/// when it is not (handler should return that response directly).
///
/// Semantics:
///   - store is empty + allowAnonPush=true  -> pass-through (Phase 7 mode)
///   - otherwise: parse Basic-auth header; verify against the store;
///                401 on missing / wrong creds.
struct GitPushBasicAuth: Sendable {
    let store: UserStore
    let tokens: TokenStore?
    let allowAnonPush: Bool

    /// Returns nil when the request is authorized; non-nil response
    /// (401) when it is not.
    ///
    /// Accepts THREE credential shapes:
    ///   1. HTTP Basic with the user's password (Phase 8 baseline).
    ///   2. HTTP Basic with a PAT in the password slot (Phase 19).
    ///      The username is ignored when the password starts with
    ///      `giteax_pat_` so any value (including the conventional
    ///      `x-token-auth`) works.
    ///   3. `Authorization: Bearer giteax_pat_…` (Phase 19).
    func gate(_ req: Request) async throws -> Response? {
        let storeEmpty = await store.isEmpty()
        if storeEmpty && allowAnonPush {
            return nil
        }
        // Bearer-PAT path.
        if let tokens, let bearer = req.headers.bearerAuthorization,
           bearer.token.hasPrefix(TokenStore.plaintextPrefix),
           let tok = try await tokens.verify(plaintext: bearer.token),
           let user = await store.get(tok.owner) {
            req.storage[GitPushAuthedUserKey.self] = user.name
            return nil
        }
        guard let basic = req.headers.basicAuthorization else {
            return Self.challenge()
        }
        // Basic-PAT path.
        if let tokens, basic.password.hasPrefix(TokenStore.plaintextPrefix),
           let tok = try await tokens.verify(plaintext: basic.password),
           let user = await store.get(tok.owner) {
            req.storage[GitPushAuthedUserKey.self] = user.name
            return nil
        }
        // Plain password path.
        guard let user = await store.verify(name: basic.username, password: basic.password) else {
            return Self.challenge()
        }
        req.storage[GitPushAuthedUserKey.self] = user.name
        return nil
    }

    private static func challenge() -> Response {
        let r = Response(status: .unauthorized)
        r.headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
        r.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        r.body = .init(string: #"{"error":true,"reason":"authentication required to push"}"#)
        return r
    }
}

/// Storage key for the authed username stashed on the `Request` by
/// `GitPushBasicAuth.gate(_:)`. Internal so the Phase 9 issue routes
/// can read it back to attribute writes.
struct GitPushAuthedUserKey: StorageKey {
    typealias Value = String
}

// MARK: - DTOs

private struct CreateUserDTO: Content {
    let name: String
    let password: String
    let isAdmin: Bool?
}

private struct UserDTO: Content {
    let name: String
    let createdAt: Date
    let isAdmin: Bool
}

private struct UsersListDTO: Content {
    let count: Int
    let users: [String]
}

private struct UsersStatusDTO: Content {
    let userCount: Int
    let adminTokenConfigured: Bool
    let isEmpty: Bool
}

// MARK: - Shared helper

private func jsonResponse<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let r = Response(status: status)
    try r.content.encode(value, as: .json)
    return r
}
