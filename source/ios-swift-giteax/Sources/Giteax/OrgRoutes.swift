import Foundation
import Vapor

/// Phase 40: Organization + team HTTP API.
///
/// Admin-token-gated endpoints (`Authorization: Bearer GITEAX_ADMIN_TOKEN`):
///
///   POST   /api/orgs                                 {name, description?, owners?}
///   DELETE /api/orgs/:org
///
/// Owner-or-admin endpoints (Basic auth, requesting user must be in
/// the org's `owners` list, OR a global admin):
///
///   PATCH  /api/orgs/:org                            {description}
///   PUT    /api/orgs/:org/owners/:user
///   DELETE /api/orgs/:org/owners/:user
///   POST   /api/orgs/:org/teams                      {name, description?, permission, members?, repos?}
///   PATCH  /api/orgs/:org/teams/:team                {description?, permission?}
///   DELETE /api/orgs/:org/teams/:team
///   PUT    /api/orgs/:org/teams/:team/members/:user
///   DELETE /api/orgs/:org/teams/:team/members/:user
///   PUT    /api/orgs/:org/teams/:team/repos/:repo
///   DELETE /api/orgs/:org/teams/:team/repos/:repo
///
/// Public read endpoints:
///
///   GET    /api/orgs                                 -> {count, orgs[]}
///   GET    /api/orgs/:org                            -> org detail
///   GET    /api/orgs/:org/teams                      -> {count, teams[]}
///   GET    /api/orgs/:org/teams/:team                -> team detail
///
/// Permissions for org-owned repos are computed by `AccessController`:
/// org owners are `.admin` on every repo; team members get the team's
/// `permission` on repos listed in `repos` (with `"*"` granting access
/// to every repo in the org). Per-repo `Meta.collaborators` still
/// applies on top.
func registerOrgRoutes(
    _ app: Application,
    orgs: OrgStore,
    users: UserStore,
    pushAuth: GitPushBasicAuth?,
    adminToken: String?
) {

    struct AdminBearer: AsyncMiddleware {
        let expected: String
        func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            guard let raw = req.headers.bearerAuthorization?.token, raw == expected else {
                throw Abort(.unauthorized, reason: "admin token required")
            }
            return try await next.respond(to: req)
        }
    }

    @Sendable
    func requireAuthed(_ req: Request) async throws -> (name: String, isAdmin: Bool) {
        guard let pushAuth else {
            throw Abort(.serviceUnavailable, reason: "auth disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm=\"giteax\""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        let user = await users.get(name)
        return (name, user?.isAdmin ?? false)
    }

    @Sendable
    func requireOrgOwnerOrAdmin(_ req: Request, org orgName: String) async throws -> String {
        let (name, isAdmin) = try await requireAuthed(req)
        if isAdmin { return name }
        guard let org = try await orgs.get(orgName) else {
            throw Abort(.notFound, reason: "no organization '\(orgName)'")
        }
        guard org.owners.contains(name) else {
            throw Abort(.forbidden, reason: "must be an owner of organization '\(orgName)' or a global admin")
        }
        return name
    }

    // MARK: - Public reads

    app.get("api", "orgs") { req async throws -> Response in
        let list = try await orgs.list()
        let dto = OrgListDTO(count: list.count, orgs: list.map(OrgDTO.from))
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.get("api", "orgs", ":org") { req async throws -> Response in
        guard let n = req.parameters.get("org") else { throw Abort(.badRequest, reason: "missing :org") }
        guard let org = try await orgs.get(n) else {
            throw Abort(.notFound, reason: "no organization '\(n)'")
        }
        let resp = Response(status: .ok)
        try resp.content.encode(OrgDTO.from(org), as: .json)
        return resp
    }

    app.get("api", "orgs", ":org", "teams") { req async throws -> Response in
        guard let n = req.parameters.get("org") else { throw Abort(.badRequest, reason: "missing :org") }
        guard let org = try await orgs.get(n) else {
            throw Abort(.notFound, reason: "no organization '\(n)'")
        }
        let dto = TeamListDTO(org: n, count: org.teams.count, teams: org.teams.map(TeamDTO.from))
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.get("api", "orgs", ":org", "teams", ":team") { req async throws -> Response in
        guard let n = req.parameters.get("org"), let t = req.parameters.get("team") else {
            throw Abort(.badRequest, reason: "missing :org/:team")
        }
        guard let org = try await orgs.get(n) else {
            throw Abort(.notFound, reason: "no organization '\(n)'")
        }
        guard let team = org.teams.first(where: { $0.name == t }) else {
            throw Abort(.notFound, reason: "no team '\(t)' in organization '\(n)'")
        }
        let resp = Response(status: .ok)
        try resp.content.encode(TeamDTO.from(team), as: .json)
        return resp
    }

    // MARK: - Admin: org create/delete

    if let adminToken {
        let admin = app.grouped(AdminBearer(expected: adminToken))

        admin.post("api", "orgs") { req async throws -> Response in
            let body = try req.content.decode(CreateOrgDTO.self)
            // Reject if a user with the same name already exists.
            if let _ = await users.get(body.name) {
                throw Abort(.conflict, reason: "user '\(body.name)' already exists; org names share the user namespace")
            }
            let createdBy = req.headers.first(name: "X-Giteax-Admin-As") ?? "(admin)"
            do {
                let org = try await orgs.createOrg(
                    name: body.name,
                    description: body.description ?? "",
                    createdBy: createdBy,
                    initialOwners: body.owners ?? []
                )
                let resp = Response(status: .created)
                try resp.content.encode(OrgDTO.from(org), as: .json)
                return resp
            } catch let e as OrgStore.StoreError {
                throw Abort(e.status, reason: e.reason)
            }
        }

        admin.delete("api", "orgs", ":org") { req async throws -> Response in
            guard let n = req.parameters.get("org") else { throw Abort(.badRequest, reason: "missing :org") }
            do {
                let removed = try await orgs.deleteOrg(name: n)
                if !removed { throw Abort(.notFound, reason: "no organization '\(n)'") }
            } catch let e as OrgStore.StoreError {
                throw Abort(e.status, reason: e.reason)
            }
            return Response(status: .noContent)
        }
    } else {
        for path in ["api/orgs", "api/orgs/:org"] {
            app.on(.POST,   path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "org admin disabled (set GITEAX_ADMIN_TOKEN)")
            }
            app.on(.DELETE, path.pathComponents) { _ async throws -> Response in
                throw Abort(.serviceUnavailable, reason: "org admin disabled (set GITEAX_ADMIN_TOKEN)")
            }
        }
    }

    // MARK: - Owner mutations

    app.patch("api", "orgs", ":org") { req async throws -> Response in
        guard let n = req.parameters.get("org") else { throw Abort(.badRequest, reason: "missing :org") }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        let body = try req.content.decode(UpdateOrgDTO.self)
        do {
            let org = try await orgs.setDescription(org: n, description: body.description)
            let resp = Response(status: .ok)
            try resp.content.encode(OrgDTO.from(org), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.put("api", "orgs", ":org", "owners", ":user") { req async throws -> Response in
        guard let n = req.parameters.get("org"), let u = req.parameters.get("user") else {
            throw Abort(.badRequest, reason: "missing :org/:user")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        guard let _ = await users.get(u) else {
            throw Abort(.badRequest, reason: "no user '\(u)'")
        }
        do {
            let org = try await orgs.addOwner(org: n, user: u)
            let resp = Response(status: .ok)
            try resp.content.encode(OrgDTO.from(org), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "orgs", ":org", "owners", ":user") { req async throws -> Response in
        guard let n = req.parameters.get("org"), let u = req.parameters.get("user") else {
            throw Abort(.badRequest, reason: "missing :org/:user")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        do {
            let org = try await orgs.removeOwner(org: n, user: u)
            let resp = Response(status: .ok)
            try resp.content.encode(OrgDTO.from(org), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    // MARK: - Team mutations

    app.post("api", "orgs", ":org", "teams") { req async throws -> Response in
        guard let n = req.parameters.get("org") else { throw Abort(.badRequest, reason: "missing :org") }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        let body = try req.content.decode(CreateTeamDTO.self)
        guard let perm = RepoMetaStore.Permission(rawValue: body.permission) else {
            throw Abort(.badRequest, reason: "permission must be read|write|admin")
        }
        do {
            let team = try await orgs.createTeam(
                org: n, name: body.name,
                description: body.description ?? "",
                permission: perm,
                members: body.members ?? [],
                repos: body.repos ?? []
            )
            let resp = Response(status: .created)
            try resp.content.encode(TeamDTO.from(team), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.patch("api", "orgs", ":org", "teams", ":team") { req async throws -> Response in
        guard let n = req.parameters.get("org"), let t = req.parameters.get("team") else {
            throw Abort(.badRequest, reason: "missing :org/:team")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        let body = try req.content.decode(UpdateTeamDTO.self)
        let perm: RepoMetaStore.Permission?
        if let raw = body.permission {
            guard let p = RepoMetaStore.Permission(rawValue: raw) else {
                throw Abort(.badRequest, reason: "permission must be read|write|admin")
            }
            perm = p
        } else { perm = nil }
        do {
            let team = try await orgs.updateTeam(
                org: n, team: t,
                description: body.description,
                permission: perm
            )
            let resp = Response(status: .ok)
            try resp.content.encode(TeamDTO.from(team), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "orgs", ":org", "teams", ":team") { req async throws -> Response in
        guard let n = req.parameters.get("org"), let t = req.parameters.get("team") else {
            throw Abort(.badRequest, reason: "missing :org/:team")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        do {
            let removed = try await orgs.deleteTeam(org: n, team: t)
            if !removed { throw Abort(.notFound, reason: "no team '\(t)' in organization '\(n)'") }
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }

    app.put("api", "orgs", ":org", "teams", ":team", "members", ":user") { req async throws -> Response in
        guard let n = req.parameters.get("org"),
              let t = req.parameters.get("team"),
              let u = req.parameters.get("user") else {
            throw Abort(.badRequest, reason: "missing :org/:team/:user")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        guard let _ = await users.get(u) else {
            throw Abort(.badRequest, reason: "no user '\(u)'")
        }
        do {
            let team = try await orgs.addTeamMember(org: n, team: t, user: u)
            let resp = Response(status: .ok)
            try resp.content.encode(TeamDTO.from(team), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "orgs", ":org", "teams", ":team", "members", ":user") { req async throws -> Response in
        guard let n = req.parameters.get("org"),
              let t = req.parameters.get("team"),
              let u = req.parameters.get("user") else {
            throw Abort(.badRequest, reason: "missing :org/:team/:user")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        do {
            let team = try await orgs.removeTeamMember(org: n, team: t, user: u)
            let resp = Response(status: .ok)
            try resp.content.encode(TeamDTO.from(team), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.put("api", "orgs", ":org", "teams", ":team", "repos", ":repo") { req async throws -> Response in
        guard let n = req.parameters.get("org"),
              let t = req.parameters.get("team"),
              let r = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :org/:team/:repo")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        do {
            let team = try await orgs.addTeamRepo(org: n, team: t, repo: r)
            let resp = Response(status: .ok)
            try resp.content.encode(TeamDTO.from(team), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "orgs", ":org", "teams", ":team", "repos", ":repo") { req async throws -> Response in
        guard let n = req.parameters.get("org"),
              let t = req.parameters.get("team"),
              let r = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :org/:team/:repo")
        }
        _ = try await requireOrgOwnerOrAdmin(req, org: n)
        do {
            let team = try await orgs.removeTeamRepo(org: n, team: t, repo: r)
            let resp = Response(status: .ok)
            try resp.content.encode(TeamDTO.from(team), as: .json)
            return resp
        } catch let e as OrgStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
}

// MARK: - DTOs

private struct CreateOrgDTO: Content {
    let name: String
    let description: String?
    let owners: [String]?
}

private struct UpdateOrgDTO: Content {
    let description: String
}

private struct OrgDTO: Content {
    let name: String
    let description: String
    let createdBy: String
    let createdAt: Date
    let owners: [String]
    let teamCount: Int

    static func from(_ o: OrgStore.Org) -> OrgDTO {
        OrgDTO(
            name: o.name, description: o.description,
            createdBy: o.createdBy, createdAt: o.createdAt,
            owners: o.owners.sorted(), teamCount: o.teams.count
        )
    }
}

private struct OrgListDTO: Content {
    let count: Int
    let orgs: [OrgDTO]
}

private struct CreateTeamDTO: Content {
    let name: String
    let description: String?
    let permission: String
    let members: [String]?
    let repos: [String]?
}

private struct UpdateTeamDTO: Content {
    let description: String?
    let permission: String?
}

private struct TeamDTO: Content {
    let name: String
    let description: String
    let permission: String
    let members: [String]
    let repos: [String]

    static func from(_ t: OrgStore.Team) -> TeamDTO {
        TeamDTO(
            name: t.name, description: t.description,
            permission: t.permission.rawValue,
            members: t.members.sorted(),
            repos: t.repos.sorted()
        )
    }
}

private struct TeamListDTO: Content {
    let org: String
    let count: Int
    let teams: [TeamDTO]
}
