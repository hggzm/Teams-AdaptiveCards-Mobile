import Foundation
import Vapor

/// Phase 45 -- avatars for users and orgs.
///
///   PUT    /api/users/:name/avatar       (auth, self-or-admin)   body: raw image bytes
///   GET    /api/users/:name/avatar       (public)                returns image bytes
///   DELETE /api/users/:name/avatar       (auth, self-or-admin)
///
///   PUT    /api/orgs/:org/avatar         (auth, org-owner-or-admin)
///   GET    /api/orgs/:org/avatar         (public)
///   DELETE /api/orgs/:org/avatar         (auth, org-owner-or-admin)
///
/// Storage layout:
///
///     <root>/.giteax/avatars/users/<name>.<ext>
///     <root>/.giteax/avatars/orgs/<name>.<ext>
///
/// Format is sniffed from the first bytes of the request body (PNG /
/// JPEG / GIF / WebP). Anything else -> 415. Hard cap 1 MiB. Both
/// the upload `Content-Type` and the sniffed format must agree (the
/// extension is taken from the sniffed format, not the header).
///
/// GETs return 404 when no avatar is set -- no fallback gravatar /
/// generated image. Clients are expected to render their own
/// placeholder on 404.
func registerAvatarRoutes(
    _ app: Application,
    users: UserStore,
    orgs: OrgStore?,
    pushAuth: GitPushBasicAuth?,
    access: AccessController,
    rootURL: URL
) {

    // MARK: - User avatars

    app.put("api", "users", ":name", "avatar") { req async throws -> Response in
        guard let target = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        let author = try await requireAuthor(req, pushAuth: pushAuth)
        let identity = await access.identify(req)
        try requireUserSelfOrAdmin(target: target, author: author, identity: identity)

        let (data, ext) = try readAndValidateAvatar(req)
        let dir = avatarDir(rootURL: rootURL, kind: .user)
        try writeAvatar(dir: dir, name: target, data: data, ext: ext)

        let resp = Response(status: .ok)
        try resp.content.encode(AvatarSetDTO(
            name: target, kind: "user", format: ext, sizeBytes: data.count
        ), as: .json)
        return resp
    }

    app.get("api", "users", ":name", "avatar") { req async throws -> Response in
        guard let target = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        return try serveAvatar(rootURL: rootURL, kind: .user, name: target)
    }

    app.delete("api", "users", ":name", "avatar") { req async throws -> Response in
        guard let target = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        let author = try await requireAuthor(req, pushAuth: pushAuth)
        let identity = await access.identify(req)
        try requireUserSelfOrAdmin(target: target, author: author, identity: identity)

        let removed = try deleteAvatar(rootURL: rootURL, kind: .user, name: target)
        if !removed { throw Abort(.notFound, reason: "no avatar set for user '\(target)'") }
        return Response(status: .noContent)
    }

    // MARK: - Org avatars (only wire if orgs are enabled)

    if let orgs {
        app.put("api", "orgs", ":org", "avatar") { req async throws -> Response in
            guard let target = req.parameters.get("org") else {
                throw Abort(.badRequest, reason: "missing :org")
            }
            let author = try await requireAuthor(req, pushAuth: pushAuth)
            let identity = await access.identify(req)
            try await requireOrgOwnerOrAdmin(target: target, author: author, identity: identity, orgs: orgs)

            let (data, ext) = try readAndValidateAvatar(req)
            let dir = avatarDir(rootURL: rootURL, kind: .org)
            try writeAvatar(dir: dir, name: target, data: data, ext: ext)

            let resp = Response(status: .ok)
            try resp.content.encode(AvatarSetDTO(
                name: target, kind: "org", format: ext, sizeBytes: data.count
            ), as: .json)
            return resp
        }

        app.get("api", "orgs", ":org", "avatar") { req async throws -> Response in
            guard let target = req.parameters.get("org") else {
                throw Abort(.badRequest, reason: "missing :org")
            }
            return try serveAvatar(rootURL: rootURL, kind: .org, name: target)
        }

        app.delete("api", "orgs", ":org", "avatar") { req async throws -> Response in
            guard let target = req.parameters.get("org") else {
                throw Abort(.badRequest, reason: "missing :org")
            }
            let author = try await requireAuthor(req, pushAuth: pushAuth)
            let identity = await access.identify(req)
            try await requireOrgOwnerOrAdmin(target: target, author: author, identity: identity, orgs: orgs)

            let removed = try deleteAvatar(rootURL: rootURL, kind: .org, name: target)
            if !removed { throw Abort(.notFound, reason: "no avatar set for org '\(target)'") }
            return Response(status: .noContent)
        }
    }
}

// MARK: - Helpers

private let avatarMaxBytes = 1 * 1024 * 1024   // 1 MiB

private enum AvatarKind { case user, org }

@Sendable
private func avatarDir(rootURL: URL, kind: AvatarKind) -> URL {
    rootURL
        .appendingPathComponent(".giteax", isDirectory: true)
        .appendingPathComponent("avatars", isDirectory: true)
        .appendingPathComponent(kind == .user ? "users" : "orgs", isDirectory: true)
}

@Sendable
private func requireAuthor(_ req: Request, pushAuth: GitPushBasicAuth?) async throws -> String {
    guard let pushAuth else {
        throw Abort(.forbidden, reason: "avatar uploads disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
    }
    if let _ = try await pushAuth.gate(req) {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
        throw Abort(.unauthorized, headers: headers, reason: "authentication required")
    }
    guard let name = req.storage[GitPushAuthedUserKey.self] else {
        throw Abort(.unauthorized, reason: "authenticated user missing")
    }
    return name
}

@Sendable
private func requireUserSelfOrAdmin(target: String, author: String, identity: AuthIdentity) throws {
    if identity.isGlobalAdmin { return }
    if author == target { return }
    throw Abort(.forbidden, reason: "only '\(target)' or a global admin can change this avatar")
}

@Sendable
private func requireOrgOwnerOrAdmin(
    target: String, author: String, identity: AuthIdentity, orgs: OrgStore
) async throws {
    if identity.isGlobalAdmin { return }
    guard let org = try await orgs.get(target) else {
        throw Abort(.notFound, reason: "no org '\(target)'")
    }
    guard org.owners.contains(author) else {
        throw Abort(.forbidden, reason: "only an owner of org '\(target)' or a global admin can change this avatar")
    }
}

/// Sniffs PNG / JPEG / GIF / WebP from the first bytes. Returns
/// the canonical file extension on success, throws 415 otherwise.
@Sendable
private func sniffImageFormat(_ data: Data) -> String? {
    guard data.count >= 12 else { return nil }
    let b = [UInt8](data.prefix(12))
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
       b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
        return "png"
    }
    // JPEG: FF D8 FF
    if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
        return "jpg"
    }
    // GIF: "GIF87a" or "GIF89a"
    if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38,
       (b[4] == 0x37 || b[4] == 0x39), b[5] == 0x61 {
        return "gif"
    }
    // WebP: "RIFF" .... "WEBP"
    if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
       b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
        return "webp"
    }
    return nil
}

@Sendable
private func contentTypeFor(ext: String) -> String {
    switch ext {
    case "png":  return "image/png"
    case "jpg":  return "image/jpeg"
    case "gif":  return "image/gif"
    case "webp": return "image/webp"
    default:     return "application/octet-stream"
    }
}

@Sendable
private func readAndValidateAvatar(_ req: Request) throws -> (Data, String) {
    guard var buf = req.body.data else {
        throw Abort(.badRequest, reason: "empty request body")
    }
    let len = buf.readableBytes
    if len == 0 { throw Abort(.badRequest, reason: "empty request body") }
    if len > avatarMaxBytes {
        throw Abort(.payloadTooLarge, reason: "avatar exceeds \(avatarMaxBytes) bytes (got \(len))")
    }
    guard let bytes = buf.readBytes(length: len) else {
        throw Abort(.badRequest, reason: "could not read request body")
    }
    let data = Data(bytes)
    guard let ext = sniffImageFormat(data) else {
        throw Abort(.unsupportedMediaType, reason: "avatar must be PNG, JPEG, GIF or WebP (magic-byte check)")
    }
    return (data, ext)
}

@Sendable
private func writeAvatar(dir: URL, name: String, data: Data, ext: String) throws {
    guard RepositoryService.validateSegment(name) else {
        throw Abort(.badRequest, reason: "name must match [A-Za-z0-9][A-Za-z0-9._-]*")
    }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        throw Abort(.internalServerError, reason: "mkdir avatars dir: \(error)")
    }
    // Remove ANY prior avatar for this name (any extension) so we
    // never end up with stale files in alternate formats.
    for old in ["png", "jpg", "gif", "webp"] {
        let p = dir.appendingPathComponent("\(name).\(old)")
        if FileManager.default.fileExists(atPath: p.path) {
            try? FileManager.default.removeItem(at: p)
        }
    }
    let url = dir.appendingPathComponent("\(name).\(ext)")
    // Portable atomic write (avoid replaceItemAt on Windows).
    let tmp = dir.appendingPathComponent("\(name).\(ext).tmp-\(ProcessInfo.processInfo.processIdentifier)")
    do {
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw Abort(.internalServerError, reason: "could not persist avatar: \(error)")
    }
}

@Sendable
private func serveAvatar(rootURL: URL, kind: AvatarKind, name: String) throws -> Response {
    guard RepositoryService.validateSegment(name) else {
        throw Abort(.badRequest, reason: "name must match [A-Za-z0-9][A-Za-z0-9._-]*")
    }
    let dir = avatarDir(rootURL: rootURL, kind: kind)
    for ext in ["png", "jpg", "gif", "webp"] {
        let p = dir.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: p.path) {
            let data = (try? Data(contentsOf: p)) ?? Data()
            let resp = Response(status: .ok)
            resp.headers.replaceOrAdd(name: .contentType,   value: contentTypeFor(ext: ext))
            resp.headers.replaceOrAdd(name: .contentLength, value: String(data.count))
            resp.headers.replaceOrAdd(name: .cacheControl,  value: "private, max-age=60")
            resp.body = .init(data: data)
            return resp
        }
    }
    throw Abort(.notFound, reason: "no avatar set")
}

@Sendable
private func deleteAvatar(rootURL: URL, kind: AvatarKind, name: String) throws -> Bool {
    guard RepositoryService.validateSegment(name) else {
        throw Abort(.badRequest, reason: "name must match [A-Za-z0-9][A-Za-z0-9._-]*")
    }
    let dir = avatarDir(rootURL: rootURL, kind: kind)
    var removed = false
    for ext in ["png", "jpg", "gif", "webp"] {
        let p = dir.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: p.path) {
            try FileManager.default.removeItem(at: p)
            removed = true
        }
    }
    return removed
}

// MARK: - DTOs

private struct AvatarSetDTO: Content {
    let name: String
    let kind: String
    let format: String
    let sizeBytes: Int
}
