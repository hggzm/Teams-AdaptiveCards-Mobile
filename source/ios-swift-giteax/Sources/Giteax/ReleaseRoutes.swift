import Foundation
import Vapor

/// Phase 13 wiring: release management + asset upload/download.
///
///   GET    /api/repos/:user/:repo/releases                       (read)
///   GET    /api/repos/:user/:repo/releases/:tag                  (read)
///   POST   /api/repos/:user/:repo/releases                       (admin) {tag, name?, body?, draft?, prerelease?}
///   PATCH  /api/repos/:user/:repo/releases/:tag                  (admin) {name?, body?, draft?, prerelease?}
///   DELETE /api/repos/:user/:repo/releases/:tag                  (admin)
///   GET    /api/repos/:user/:repo/releases/:tag/assets/:file     (read)  -> raw bytes
///   PUT    /api/repos/:user/:repo/releases/:tag/assets/:file     (admin) body: asset bytes (any content type)
///   DELETE /api/repos/:user/:repo/releases/:tag/assets/:file     (admin)
///
/// Asset upload uses PUT with the raw bytes as the body (max 256 MiB).
/// Content-Type header is preserved and replayed on download.
func registerReleaseRoutes(
    _ app: Application,
    store: ReleaseStore,
    access: AccessController?,
    pushAuth: GitPushBasicAuth?
) {

    @Sendable
    func gateRead(_ req: Request, user: String, repo: String) async throws {
        guard let access else { return }
        let identity = await access.identify(req)
        do {
            try await access.requireRead(identity, user: user, repo: repo, scope: "this repository")
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
    }

    @Sendable
    func requireAdmin(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "release management is disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required for release management")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .admin, user: user, repo: repo,
                    scope: "managing releases"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    // MARK: - Read

    app.get("api", "repos", ":user", ":repo", "releases") { req async throws -> Response in
        let (u, r) = try relRepoParams(req)
        try await gateRead(req, user: u, repo: r)
        let rels: [ReleaseStore.Release]
        do {
            rels = try await store.list(user: u, repo: r)
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try relJSON(ReleaseListDTO(user: u, repo: r, count: rels.count, releases: rels.map(ReleaseDTO.from)))
    }

    app.get("api", "repos", ":user", ":repo", "releases", ":tag") { req async throws -> Response in
        let (u, r, t) = try relTagParams(req)
        try await gateRead(req, user: u, repo: r)
        let rel: ReleaseStore.Release
        do {
            rel = try await store.get(user: u, repo: r, tag: t)
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try relJSON(ReleaseDTO.from(rel))
    }

    /// Asset download — streams the file bytes back with the recorded
    /// content-type. The actor serialises reads; large files are bounded
    /// by the 256 MiB upload cap.
    app.get("api", "repos", ":user", ":repo", "releases", ":tag", "assets", ":file") { req async throws -> Response in
        let (u, r, t) = try relTagParams(req)
        guard let file = req.parameters.get("file") else {
            throw Abort(.badRequest, reason: "missing :file")
        }
        try await gateRead(req, user: u, repo: r)
        let (asset, data): (ReleaseStore.Asset, Data)
        do {
            (asset, data) = try await store.readAsset(user: u, repo: r, tag: t, filename: file)
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let resp = Response(status: .ok)
        resp.headers.replaceOrAdd(name: .contentType, value: asset.contentType)
        resp.headers.replaceOrAdd(name: .contentLength, value: String(data.count))
        resp.headers.replaceOrAdd(name: "X-Giteax-Asset-Tag", value: t)
        resp.headers.replaceOrAdd(name: .contentDisposition, value: #"attachment; filename="\#(asset.filename)""#)
        resp.body = .init(data: data)
        return resp
    }

    // MARK: - Write

    app.post("api", "repos", ":user", ":repo", "releases") { req async throws -> Response in
        let (u, r) = try relRepoParams(req)
        let author = try await requireAdmin(req, user: u, repo: r)
        let body = try req.content.decode(CreateReleaseDTO.self)
        let rel: ReleaseStore.Release
        do {
            rel = try await store.create(
                user: u, repo: r,
                tag: body.tag,
                name: body.name,
                body: body.body ?? "",
                draft: body.draft ?? false,
                prerelease: body.prerelease ?? false,
                authorName: author
            )
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try relJSON(ReleaseDTO.from(rel), status: .created)
    }

    app.patch("api", "repos", ":user", ":repo", "releases", ":tag") { req async throws -> Response in
        let (u, r, t) = try relTagParams(req)
        _ = try await requireAdmin(req, user: u, repo: r)
        let body = try req.content.decode(UpdateReleaseDTO.self)
        let rel: ReleaseStore.Release
        do {
            rel = try await store.update(
                user: u, repo: r, tag: t,
                name: body.name, body: body.body,
                draft: body.draft, prerelease: body.prerelease
            )
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try relJSON(ReleaseDTO.from(rel))
    }

    app.delete("api", "repos", ":user", ":repo", "releases", ":tag") { req async throws -> Response in
        let (u, r, t) = try relTagParams(req)
        _ = try await requireAdmin(req, user: u, repo: r)
        do {
            try await store.delete(user: u, repo: r, tag: t)
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }

    /// Upload (or replace) an asset on an existing release. Body is
    /// the raw bytes; Content-Type is preserved.
    app.put("api", "repos", ":user", ":repo", "releases", ":tag", "assets", ":file") { req async throws -> Response in
        let (u, r, t) = try relTagParams(req)
        guard let file = req.parameters.get("file") else {
            throw Abort(.badRequest, reason: "missing :file")
        }
        _ = try await requireAdmin(req, user: u, repo: r)
        let body: Data
        if let buffer = req.body.data {
            body = Data(buffer: buffer)
        } else {
            let collected = try await req.body.collect(max: 256 * 1024 * 1024).get()
            if let buffer = collected {
                body = Data(buffer: buffer)
            } else {
                body = Data()
            }
        }
        guard !body.isEmpty else {
            throw Abort(.badRequest, reason: "asset body is empty")
        }
        let contentType = req.headers.first(name: .contentType) ?? "application/octet-stream"
        let asset: ReleaseStore.Asset
        do {
            asset = try await store.upsertAsset(
                user: u, repo: r, tag: t,
                filename: file, contentType: contentType, data: body
            )
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try relJSON(AssetDTO.from(asset), status: .created)
    }

    app.delete("api", "repos", ":user", ":repo", "releases", ":tag", "assets", ":file") { req async throws -> Response in
        let (u, r, t) = try relTagParams(req)
        guard let file = req.parameters.get("file") else {
            throw Abort(.badRequest, reason: "missing :file")
        }
        _ = try await requireAdmin(req, user: u, repo: r)
        do {
            try await store.deleteAsset(user: u, repo: r, tag: t, filename: file)
        } catch let e as ReleaseStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }
}

// MARK: - DTOs

private struct CreateReleaseDTO: Content {
    let tag: String
    let name: String?
    let body: String?
    let draft: Bool?
    let prerelease: Bool?
}

private struct UpdateReleaseDTO: Content {
    let name: String?
    let body: String?
    let draft: Bool?
    let prerelease: Bool?
}

private struct ReleaseDTO: Content {
    let tag: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let authorName: String
    let createdAt: Date
    let updatedAt: Date
    let assets: [AssetDTO]

    static func from(_ r: ReleaseStore.Release) -> ReleaseDTO {
        ReleaseDTO(
            tag: r.tag,
            name: r.name,
            body: r.body,
            draft: r.draft,
            prerelease: r.prerelease,
            authorName: r.authorName,
            createdAt: r.createdAt,
            updatedAt: r.updatedAt,
            assets: r.assets.map(AssetDTO.from)
        )
    }
}

private struct AssetDTO: Content {
    let filename: String
    let size: Int
    let contentType: String
    let uploadedAt: Date

    static func from(_ a: ReleaseStore.Asset) -> AssetDTO {
        AssetDTO(filename: a.filename, size: a.size, contentType: a.contentType, uploadedAt: a.uploadedAt)
    }
}

private struct ReleaseListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let releases: [ReleaseDTO]
}

// MARK: - Helpers

private func relRepoParams(_ req: Request) throws -> (String, String) {
    guard let user = req.parameters.get("user"),
          let repo = req.parameters.get("repo")
    else { throw Abort(.badRequest, reason: "missing :user or :repo") }
    return (user, repo)
}

private func relTagParams(_ req: Request) throws -> (String, String, String) {
    guard let user = req.parameters.get("user"),
          let repo = req.parameters.get("repo"),
          let tag = req.parameters.get("tag")
    else { throw Abort(.badRequest, reason: "missing :user, :repo or :tag") }
    return (user, repo, tag)
}

private func relJSON<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let r = Response(status: status)
    try r.content.encode(value, as: .json)
    return r
}
