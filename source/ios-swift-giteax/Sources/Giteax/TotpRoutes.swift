import Foundation
import Vapor

/// Phase 46 -- TOTP (RFC 6238) two-factor auth enrollment endpoints.
///
///   POST   /api/users/:name/2fa/setup           (auth, self)
///       -> { secret, otpauthURI, recoveryCodes[] }  -- ONE-TIME
///   POST   /api/users/:name/2fa/activate         (auth, self)
///       body: { code: "123456" }
///       -> 204 on success; 400 on wrong code or no pending setup
///   POST   /api/users/:name/2fa/verify           (auth, self)
///       body: { code: "123456" }
///       -> 204 on success; 401 on wrong code or not active
///   POST   /api/users/:name/2fa/recovery/use     (auth, self)
///       body: { code: "abcd-efghij" }
///       -> 204 on success; 401 on wrong code (case-insensitive,
///          dash/space-stripped); single-use.
///   GET    /api/users/:name/2fa/status           (auth, self-or-admin)
///       -> { enabled, pending, recoveryCodesRemaining }
///   DELETE /api/users/:name/2fa                  (auth, self-or-admin)
///       -> 204 if removed; 404 if nothing to remove
///
/// Enforcement is intentionally NOT wired into the existing password
/// verify paths in this phase -- enrollment + verification surface
/// only. A follow-up phase can route smart-http / SSH password auth
/// through `TotpStore.verify` when an account has 2FA active.
func registerTotpRoutes(
    _ app: Application,
    totp: TotpStore,
    users: UserStore,
    pushAuth: GitPushBasicAuth?,
    access: AccessController,
    adminToken: String?
) {

    @Sendable
    func isAdminBearer(_ req: Request) -> Bool {
        guard let adminToken,
              let b = req.headers.bearerAuthorization,
              b.token == adminToken else { return false }
        return true
    }

    app.post("api", "users", ":name", "2fa", "setup") { req async throws -> Response in
        let target = try paramName(req)
        let author = try await totpRequireAuthor(req, pushAuth: pushAuth)
        try totpRequireSelf(target: target, author: author)
        try await totpRequireUserExists(users, target)
        let result = try await totp.setup(user: target)
        let resp = Response(status: .ok)
        try resp.content.encode(TotpSetupDTO(
            name: target,
            secret: result.secret,
            otpauthURI: result.otpauthURI,
            recoveryCodes: result.recoveryCodes
        ), as: .json)
        return resp
    }

    app.post("api", "users", ":name", "2fa", "activate") { req async throws -> Response in
        let target = try paramName(req)
        let author = try await totpRequireAuthor(req, pushAuth: pushAuth)
        try totpRequireSelf(target: target, author: author)
        let body = try req.content.decode(TotpCodeDTO.self)
        let ok = try await totp.activate(user: target, code: body.code)
        if !ok { throw Abort(.badRequest, reason: "invalid code or no pending setup") }
        return Response(status: .noContent)
    }

    app.post("api", "users", ":name", "2fa", "verify") { req async throws -> Response in
        let target = try paramName(req)
        let author = try await totpRequireAuthor(req, pushAuth: pushAuth)
        try totpRequireSelf(target: target, author: author)
        let body = try req.content.decode(TotpCodeDTO.self)
        let ok = await totp.verify(user: target, code: body.code)
        if !ok { throw Abort(.unauthorized, reason: "invalid totp code") }
        return Response(status: .noContent)
    }

    app.post("api", "users", ":name", "2fa", "recovery", "use") { req async throws -> Response in
        let target = try paramName(req)
        let author = try await totpRequireAuthor(req, pushAuth: pushAuth)
        try totpRequireSelf(target: target, author: author)
        let body = try req.content.decode(TotpCodeDTO.self)
        let ok = try await totp.useRecoveryCode(user: target, code: body.code)
        if !ok { throw Abort(.unauthorized, reason: "invalid recovery code") }
        return Response(status: .noContent)
    }

    app.get("api", "users", ":name", "2fa", "status") { req async throws -> Response in
        let target = try paramName(req)
        if !isAdminBearer(req) {
            let author = try await totpRequireAuthor(req, pushAuth: pushAuth)
            let identity = await access.identify(req)
            try totpRequireSelfOrAdmin(target: target, author: author, identity: identity)
        }
        let s = await totp.status(user: target)
        let remaining = await totp.recoveryCodeCount(user: target)
        let resp = Response(status: .ok)
        try resp.content.encode(TotpStatusDTO(
            name: target,
            enabled: s.enabled,
            pending: s.pending,
            recoveryCodesRemaining: remaining
        ), as: .json)
        return resp
    }

    app.delete("api", "users", ":name", "2fa") { req async throws -> Response in
        let target = try paramName(req)
        if !isAdminBearer(req) {
            let author = try await totpRequireAuthor(req, pushAuth: pushAuth)
            let identity = await access.identify(req)
            try totpRequireSelfOrAdmin(target: target, author: author, identity: identity)
        }
        let removed = try await totp.disable(user: target)
        if !removed { throw Abort(.notFound, reason: "no 2fa entry for '\(target)'") }
        return Response(status: .noContent)
    }
}

// MARK: - DTOs

private struct TotpSetupDTO: Content {
    let name: String
    let secret: String
    let otpauthURI: String
    let recoveryCodes: [String]
}

private struct TotpStatusDTO: Content {
    let name: String
    let enabled: Bool
    let pending: Bool
    let recoveryCodesRemaining: Int
}

private struct TotpCodeDTO: Content {
    let code: String
}

// MARK: - Helpers

@Sendable
private func paramName(_ req: Request) throws -> String {
    guard let n = req.parameters.get("name") else {
        throw Abort(.badRequest, reason: "missing :name")
    }
    guard RepositoryService.validateSegment(n) else {
        throw Abort(.badRequest, reason: "name must match [A-Za-z0-9][A-Za-z0-9._-]*")
    }
    return n
}

@Sendable
private func totpRequireAuthor(_ req: Request, pushAuth: GitPushBasicAuth?) async throws -> String {
    guard let pushAuth else {
        throw Abort(.forbidden, reason: "2fa requires user accounts (set GITEAX_ALLOW_PUSH=1 and create users)")
    }
    if let _ = try await pushAuth.gate(req) {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
        throw Abort(.unauthorized, headers: headers, reason: "authentication required")
    }
    guard let n = req.storage[GitPushAuthedUserKey.self] else {
        throw Abort(.unauthorized, reason: "authenticated user missing")
    }
    return n
}

@Sendable
private func totpRequireSelf(target: String, author: String) throws {
    if author == target { return }
    throw Abort(.forbidden, reason: "only '\(target)' can manage their own 2fa enrollment")
}

@Sendable
private func totpRequireSelfOrAdmin(target: String, author: String, identity: AuthIdentity) throws {
    if identity.isGlobalAdmin { return }
    if author == target { return }
    throw Abort(.forbidden, reason: "only '\(target)' or a global admin can view/disable this 2fa entry")
}

@Sendable
private func totpRequireUserExists(_ users: UserStore, _ name: String) async throws {
    if await users.get(name) == nil {
        throw Abort(.notFound, reason: "no such user: '\(name)'")
    }
}
