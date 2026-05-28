import Foundation
import Vapor

/// Phase 12: per-repo settings + collaborator management.
///
///   GET    /api/repos/:user/:repo/settings           (read)
///   PATCH  /api/repos/:user/:repo/settings           (admin)
///   GET    /api/repos/:user/:repo/collaborators      (admin)
///   PUT    /api/repos/:user/:repo/collaborators/:name (admin) body: {permission}
///   DELETE /api/repos/:user/:repo/collaborators/:name (admin)
///
/// PATCH body keys are all optional:
///   { "visibility": "public|private|internal",
///     "description": "...",
///     "defaultBranch": "main" }
///
/// PUT body:
///   { "permission": "read|write|admin" }
func registerRepoMetaRoutes(
    _ app: Application,
    meta: RepoMetaStore,
    access: AccessController
) {
    app.get("api", "repos", ":user", ":repo", "settings") { req async throws -> Response in
        let (u, r) = try metaRepoParams(req)
        let identity = await access.identify(req)
        try await access.requireRead(identity, user: u, repo: r, scope: "settings")
        let m: RepoMetaStore.Meta
        do {
            m = try await meta.get(user: u, repo: r)
        } catch let e as RepoMetaStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try metaJSON(SettingsDTO.from(user: u, repo: r, m: m))
    }

    app.patch("api", "repos", ":user", ":repo", "settings") { req async throws -> Response in
        let (u, r) = try metaRepoParams(req)
        let identity = await access.identify(req)
        try await access.require(identity, atLeast: .admin, user: u, repo: r, scope: "editing settings")
        let body = try req.content.decode(UpdateSettingsDTO.self)
        var v: RepoMetaStore.Visibility? = nil
        if let raw = body.visibility {
            guard let parsed = RepoMetaStore.Visibility(rawValue: raw) else {
                throw Abort(.badRequest, reason: "visibility must be public|private|internal")
            }
            v = parsed
        }
        let m: RepoMetaStore.Meta
        do {
            m = try await meta.update(
                user: u, repo: r,
                visibility: v,
                description: body.description,
                defaultBranch: body.defaultBranch,
                protectedBranches: body.protectedBranches,
                requiredApprovals: body.requiredApprovals
            )
        } catch let e as RepoMetaStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try metaJSON(SettingsDTO.from(user: u, repo: r, m: m))
    }

    app.get("api", "repos", ":user", ":repo", "collaborators") { req async throws -> Response in
        let (u, r) = try metaRepoParams(req)
        let identity = await access.identify(req)
        try await access.require(identity, atLeast: .admin, user: u, repo: r, scope: "listing collaborators")
        let m: RepoMetaStore.Meta
        do {
            m = try await meta.get(user: u, repo: r)
        } catch let e as RepoMetaStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let rows = m.collaborators
            .map { CollabDTO(name: $0.key, permission: $0.value.rawValue) }
            .sorted { $0.name < $1.name }
        return try metaJSON(CollaboratorsDTO(user: u, repo: r, count: rows.count, collaborators: rows))
    }

    app.put("api", "repos", ":user", ":repo", "collaborators", ":name") { req async throws -> Response in
        let (u, r) = try metaRepoParams(req)
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        let identity = await access.identify(req)
        try await access.require(identity, atLeast: .admin, user: u, repo: r, scope: "managing collaborators")
        let body = try req.content.decode(SetCollabDTO.self)
        guard let perm = RepoMetaStore.Permission(rawValue: body.permission) else {
            throw Abort(.badRequest, reason: "permission must be read|write|admin")
        }
        do {
            try await meta.setCollaborator(user: u, repo: r, name: name, permission: perm)
        } catch let e as RepoMetaStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try metaJSON(CollabDTO(name: name, permission: perm.rawValue), status: .created)
    }

    app.delete("api", "repos", ":user", ":repo", "collaborators", ":name") { req async throws -> Response in
        let (u, r) = try metaRepoParams(req)
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        let identity = await access.identify(req)
        try await access.require(identity, atLeast: .admin, user: u, repo: r, scope: "removing collaborators")
        do {
            try await meta.removeCollaborator(user: u, repo: r, name: name)
        } catch let e as RepoMetaStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }
}

// MARK: - DTOs

private struct UpdateSettingsDTO: Content {
    let visibility: String?
    let description: String?
    let defaultBranch: String?
    let protectedBranches: [String]?
    let requiredApprovals: Int?
}

private struct SettingsDTO: Content {
    let user: String
    let repo: String
    let visibility: String
    let description: String?
    let defaultBranch: String?
    let protectedBranches: [String]
    let requiredApprovals: Int
    let collaboratorCount: Int

    static func from(user: String, repo: String, m: RepoMetaStore.Meta) -> SettingsDTO {
        SettingsDTO(
            user: user, repo: repo,
            visibility: m.visibility.rawValue,
            description: m.description,
            defaultBranch: m.defaultBranch,
            protectedBranches: m.protectedBranches ?? [],
            requiredApprovals: m.requiredApprovals ?? 0,
            collaboratorCount: m.collaborators.count
        )
    }
}

private struct SetCollabDTO: Content {
    let permission: String
}

private struct CollabDTO: Content {
    let name: String
    let permission: String
}

private struct CollaboratorsDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let collaborators: [CollabDTO]
}

// MARK: - Helpers

private func metaRepoParams(_ req: Request) throws -> (String, String) {
    guard let user = req.parameters.get("user"),
          let repo = req.parameters.get("repo")
    else { throw Abort(.badRequest, reason: "missing :user or :repo") }
    return (user, repo)
}

private func metaJSON<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let r = Response(status: status)
    try r.content.encode(value, as: .json)
    return r
}
