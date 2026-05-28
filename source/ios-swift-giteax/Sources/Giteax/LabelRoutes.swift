import Foundation
import Vapor

/// Phase 42 -- per-repo label + milestone HTTP routes.
///
/// Labels (NAME-keyed):
///   GET    /api/repos/:user/:repo/labels                (public read)
///   POST   /api/repos/:user/:repo/labels                (write) {name,color,description?}
///   GET    /api/repos/:user/:repo/labels/:name          (public read)
///   PATCH  /api/repos/:user/:repo/labels/:name          (write) {color?,description?}
///   DELETE /api/repos/:user/:repo/labels/:name          (write)
///
/// Milestones (NUMBER-keyed):
///   GET    /api/repos/:user/:repo/milestones[?state=]   (public read)
///   POST   /api/repos/:user/:repo/milestones            (write) {title,description?,dueOn?}
///   GET    /api/repos/:user/:repo/milestones/:number    (public read)
///   PATCH  /api/repos/:user/:repo/milestones/:number    (write) {title?,description?,dueOn?,state?}
///   DELETE /api/repos/:user/:repo/milestones/:number    (write)
///
/// Auth follows the same shape as IssueRoutes: reads gated via
/// `AccessController.requireRead`; writes via Basic-against-UserStore
/// (pushAuth) + `AccessController.require(.write)`.
func registerLabelRoutes(
    _ app: Application,
    labels: LabelStore,
    milestones: MilestoneStore,
    pushAuth: GitPushBasicAuth?,
    access: AccessController? = nil
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
    func requireWrite(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "writes are disabled (set GITEAX_ALLOW_PUSH=1)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write, user: user, repo: repo,
                    scope: "writing labels/milestones"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    // ───────────────────────── Labels ─────────────────────────

    app.get("api", "repos", ":user", ":repo", "labels") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        try await gateRead(req, user: user, repo: repo)
        let list: [LabelStore.Label]
        do {
            list = try await labels.list(user: user, repo: repo)
        } catch let e as LabelStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(LabelListDTO(
            user: user, repo: repo,
            count: list.count, labels: list.map(LabelDTO.from)))
    }

    app.get("api", "repos", ":user", ":repo", "labels", ":name") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let name = req.parameters.get("name")
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :name") }
        try await gateRead(req, user: user, repo: repo)
        let l: LabelStore.Label
        do {
            l = try await labels.get(user: user, repo: repo, name: name)
        } catch let e as LabelStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(LabelDTO.from(l))
    }

    app.post("api", "repos", ":user", ":repo", "labels") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        _ = try await requireWrite(req, user: user, repo: repo)
        let body = try req.content.decode(CreateLabelDTO.self)
        let l: LabelStore.Label
        do {
            l = try await labels.create(
                user: user, repo: repo,
                name: body.name, color: body.color,
                description: body.description ?? "")
        } catch let e as LabelStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(LabelDTO.from(l), status: .created)
    }

    app.patch("api", "repos", ":user", ":repo", "labels", ":name") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let name = req.parameters.get("name")
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :name") }
        _ = try await requireWrite(req, user: user, repo: repo)
        let body = try req.content.decode(UpdateLabelDTO.self)
        let l: LabelStore.Label
        do {
            l = try await labels.update(user: user, repo: repo, name: name,
                                        color: body.color, description: body.description)
        } catch let e as LabelStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(LabelDTO.from(l))
    }

    app.delete("api", "repos", ":user", ":repo", "labels", ":name") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let name = req.parameters.get("name")
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :name") }
        _ = try await requireWrite(req, user: user, repo: repo)
        do {
            try await labels.delete(user: user, repo: repo, name: name)
        } catch let e as LabelStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }

    // ───────────────────────── Milestones ─────────────────────────

    app.get("api", "repos", ":user", ":repo", "milestones") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        try await gateRead(req, user: user, repo: repo)
        let raw = req.query[String.self, at: "state"]?.lowercased()
        let stateFilter: MilestoneStore.State?
        switch raw {
        case nil, "", "all": stateFilter = nil
        case "open":         stateFilter = .open
        case "closed":       stateFilter = .closed
        default:             throw Abort(.badRequest, reason: "state must be open|closed|all")
        }
        let list: [MilestoneStore.Milestone]
        do {
            list = try await milestones.list(user: user, repo: repo, state: stateFilter)
        } catch let e as MilestoneStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(MilestoneListDTO(
            user: user, repo: repo,
            state: raw ?? "all",
            count: list.count,
            milestones: list.map(MilestoneDTO.from)))
    }

    app.get("api", "repos", ":user", ":repo", "milestones", ":number") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        try await gateRead(req, user: user, repo: repo)
        let m: MilestoneStore.Milestone
        do {
            m = try await milestones.get(user: user, repo: repo, number: n)
        } catch let e as MilestoneStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(MilestoneDTO.from(m))
    }

    app.post("api", "repos", ":user", ":repo", "milestones") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        _ = try await requireWrite(req, user: user, repo: repo)
        let body = try req.content.decode(CreateMilestoneDTO.self)
        let due = try parseDueOn(body.dueOn)
        let m: MilestoneStore.Milestone
        do {
            m = try await milestones.create(
                user: user, repo: repo,
                title: body.title,
                description: body.description ?? "",
                dueOn: due)
        } catch let e as MilestoneStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(MilestoneDTO.from(m), status: .created)
    }

    app.patch("api", "repos", ":user", ":repo", "milestones", ":number") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        _ = try await requireWrite(req, user: user, repo: repo)
        let body = try req.content.decode(UpdateMilestoneDTO.self)
        var stateEnum: MilestoneStore.State? = nil
        if let raw = body.state {
            guard let parsed = MilestoneStore.State(rawValue: raw) else {
                throw Abort(.badRequest, reason: "state must be open|closed")
            }
            stateEnum = parsed
        }
        // Distinguish "no key" from "explicit null/empty string".
        let dueArg: Date??
        if let raw = body.dueOn {
            if raw.isEmpty {
                dueArg = .some(nil)   // explicit clear
            } else {
                dueArg = .some(try parseDueOn(raw))
            }
        } else {
            dueArg = nil              // leave alone
        }
        let m: MilestoneStore.Milestone
        do {
            m = try await milestones.update(
                user: user, repo: repo, number: n,
                title: body.title,
                description: body.description,
                dueOn: dueArg,
                state: stateEnum)
        } catch let e as MilestoneStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(MilestoneDTO.from(m))
    }

    app.delete("api", "repos", ":user", ":repo", "milestones", ":number") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        _ = try await requireWrite(req, user: user, repo: repo)
        do {
            try await milestones.delete(user: user, repo: repo, number: n)
        } catch let e as MilestoneStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }
}

private func parseDueOn(_ raw: String?) throws -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    if let d = fmt.date(from: raw) { return d }
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fmt.date(from: raw) { return d }
    // Plain YYYY-MM-DD: treat as midnight UTC.
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .iso8601)
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(identifier: "UTC")
    df.dateFormat = "yyyy-MM-dd"
    if let d = df.date(from: raw) { return d }
    throw Abort(.badRequest, reason: "dueOn must be ISO-8601 (e.g. 2026-12-31 or 2026-12-31T00:00:00Z)")
}

// MARK: - DTOs

private struct CreateLabelDTO: Content {
    let name: String
    let color: String
    let description: String?
}
private struct UpdateLabelDTO: Content {
    let color: String?
    let description: String?
}
private struct LabelDTO: Content {
    let name: String
    let color: String
    let description: String
    let createdAt: Date
    let updatedAt: Date
    static func from(_ l: LabelStore.Label) -> LabelDTO {
        LabelDTO(name: l.name, color: l.color, description: l.description,
                 createdAt: l.createdAt, updatedAt: l.updatedAt)
    }
}
private struct LabelListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let labels: [LabelDTO]
}

private struct CreateMilestoneDTO: Content {
    let title: String
    let description: String?
    let dueOn: String?
}
private struct UpdateMilestoneDTO: Content {
    let title: String?
    let description: String?
    let dueOn: String?
    let state: String?
}
private struct MilestoneDTO: Content {
    let number: Int
    let title: String
    let description: String
    let dueOn: Date?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    static func from(_ m: MilestoneStore.Milestone) -> MilestoneDTO {
        MilestoneDTO(
            number: m.number, title: m.title, description: m.description,
            dueOn: m.dueOn, state: m.state.rawValue,
            createdAt: m.createdAt, updatedAt: m.updatedAt, closedAt: m.closedAt)
    }
}
private struct MilestoneListDTO: Content {
    let user: String
    let repo: String
    let state: String
    let count: Int
    let milestones: [MilestoneDTO]
}

private func jsonResp<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let resp = Response(status: status)
    resp.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    resp.body = .init(data: data)
    return resp
}
