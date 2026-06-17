import Foundation
import Vapor

/// Phase 43 -- stars, watches, activity feed HTTP routes.
///
/// Stars:
///   PUT    /api/repos/:user/:repo/star           (auth)  current user stars
///   DELETE /api/repos/:user/:repo/star           (auth)  current user unstars
///   GET    /api/repos/:user/:repo/star           (auth)  { starred: bool }
///   GET    /api/repos/:user/:repo/stargazers     (public, read-gated)
///   GET    /api/users/:name/starred              (public)
///
/// Watches:
///   PUT    /api/repos/:user/:repo/watch          (auth)
///   DELETE /api/repos/:user/:repo/watch          (auth)
///   GET    /api/repos/:user/:repo/watch          (auth)  { watching: bool }
///   GET    /api/repos/:user/:repo/watchers       (public, read-gated)
///   GET    /api/users/:name/watched              (public)
///
/// Feed:
///   GET    /api/repos/:user/:repo/activity       (public, read-gated)
///   GET    /api/users/:name/feed                 (auth; self or admin)
///
/// Auth model:
///   - All write-style endpoints (star/unstar/watch/unwatch/feed) use
///     `pushAuth.gate` so both Basic and PAT credentials work.
///   - Read endpoints either are public, or read-gated through the
///     AccessController (private repos return 404 to anonymous).
///   - `/api/users/:name/feed` requires the caller be `name` itself
///     or a global admin.
func registerStarWatchRoutes(
    _ app: Application,
    stars: StarStore,
    watches: WatchStore,
    activity: ActivityStore,
    users: UserStore,
    pushAuth: GitPushBasicAuth?,
    access: AccessController? = nil,
    rootURL: URL
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
    func requireAuthed(_ req: Request) async throws -> String {
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
        return name
    }

    @Sendable
    func repoExists(user: String, repo: String) -> Bool {
        let bare = rootURL.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = rootURL.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    // ───────────────────────── Stars ─────────────────────────

    app.put("api", "repos", ":user", ":repo", "star") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let actor = try await requireAuthed(req)
        guard repoExists(user: u, repo: r) else {
            throw Abort(.notFound, reason: "no repository at \(u)/\(r)")
        }
        try await gateRead(req, user: u, repo: r)
        let s: StarStore.Star
        do {
            s = try await stars.star(by: actor, repoOwner: u, repoName: r)
        } catch let e as StarStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let count = (try? await stars.count(repoOwner: u, repoName: r)) ?? 0
        _ = await activity.record(
            user: u, repo: r,
            event: "star", actor: actor,
            summary: "\(actor) starred")
        return try jsonRespSW(StarStatusDTO(
            user: u, repo: r,
            starred: true,
            stargazerCount: count,
            createdAt: s.createdAt),
            status: .created)
    }

    app.delete("api", "repos", ":user", ":repo", "star") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let actor = try await requireAuthed(req)
        guard repoExists(user: u, repo: r) else {
            throw Abort(.notFound, reason: "no repository at \(u)/\(r)")
        }
        do {
            try await stars.unstar(by: actor, repoOwner: u, repoName: r)
        } catch let e as StarStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        _ = await activity.record(
            user: u, repo: r,
            event: "unstar", actor: actor,
            summary: "\(actor) unstarred")
        return Response(status: .noContent)
    }

    app.get("api", "repos", ":user", ":repo", "star") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let actor = try await requireAuthed(req)
        try await gateRead(req, user: u, repo: r)
        let starred = (try? await stars.isStarred(by: actor, repoOwner: u, repoName: r)) ?? false
        let count   = (try? await stars.count(repoOwner: u, repoName: r)) ?? 0
        return try jsonRespSW(StarStatusDTO(
            user: u, repo: r,
            starred: starred,
            stargazerCount: count,
            createdAt: nil))
    }

    app.get("api", "repos", ":user", ":repo", "stargazers") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        try await gateRead(req, user: u, repo: r)
        let list = (try? await stars.stargazers(repoOwner: u, repoName: r)) ?? []
        return try jsonRespSW(StargazerListDTO(
            user: u, repo: r,
            count: list.count,
            stargazers: list.map { StargazerDTO(name: $0.owner, createdAt: $0.createdAt) }))
    }

    app.get("api", "users", ":name", "starred") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        if await users.get(name) == nil {
            throw Abort(.notFound, reason: "no such user: '\(name)'")
        }
        let raw = (try? await stars.starredBy(user: name)) ?? []
        // Filter out repos the requester can't read.
        var visible: [StarStore.Star] = []
        let identity = await (access?.identify(req) ?? .anonymous)
        for s in raw {
            if let access {
                do {
                    try await access.requireRead(identity, user: s.repoOwner, repo: s.repoName, scope: "")
                    visible.append(s)
                } catch { /* drop */ }
            } else {
                visible.append(s)
            }
        }
        return try jsonRespSW(StarredByUserDTO(
            user: name,
            count: visible.count,
            stars: visible.map {
                StarredRepoDTO(owner: $0.repoOwner, repo: $0.repoName, createdAt: $0.createdAt)
            }))
    }

    // ───────────────────────── Watches ─────────────────────────

    app.put("api", "repos", ":user", ":repo", "watch") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let actor = try await requireAuthed(req)
        guard repoExists(user: u, repo: r) else {
            throw Abort(.notFound, reason: "no repository at \(u)/\(r)")
        }
        try await gateRead(req, user: u, repo: r)
        let w: WatchStore.Watch
        do {
            w = try await watches.watch(by: actor, repoOwner: u, repoName: r)
        } catch let e as WatchStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonRespSW(WatchStatusDTO(
            user: u, repo: r,
            watching: true,
            createdAt: w.createdAt),
            status: .created)
    }

    app.delete("api", "repos", ":user", ":repo", "watch") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let actor = try await requireAuthed(req)
        guard repoExists(user: u, repo: r) else {
            throw Abort(.notFound, reason: "no repository at \(u)/\(r)")
        }
        do {
            try await watches.unwatch(by: actor, repoOwner: u, repoName: r)
        } catch let e as WatchStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }

    app.get("api", "repos", ":user", ":repo", "watch") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        let actor = try await requireAuthed(req)
        try await gateRead(req, user: u, repo: r)
        let on = (try? await watches.isWatching(actor, repoOwner: u, repoName: r)) ?? false
        return try jsonRespSW(WatchStatusDTO(
            user: u, repo: r,
            watching: on,
            createdAt: nil))
    }

    app.get("api", "repos", ":user", ":repo", "watchers") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        try await gateRead(req, user: u, repo: r)
        let list = (try? await watches.watchers(repoOwner: u, repoName: r)) ?? []
        return try jsonRespSW(WatcherListDTO(
            user: u, repo: r,
            count: list.count,
            watchers: list.map { WatcherDTO(name: $0.owner, createdAt: $0.createdAt) }))
    }

    app.get("api", "users", ":name", "watched") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        if await users.get(name) == nil {
            throw Abort(.notFound, reason: "no such user: '\(name)'")
        }
        let raw = (try? await watches.watchedBy(user: name)) ?? []
        var visible: [WatchStore.Watch] = []
        let identity = await (access?.identify(req) ?? .anonymous)
        for w in raw {
            if let access {
                do {
                    try await access.requireRead(identity, user: w.repoOwner, repo: w.repoName, scope: "")
                    visible.append(w)
                } catch { /* drop */ }
            } else {
                visible.append(w)
            }
        }
        return try jsonRespSW(WatchedByUserDTO(
            user: name,
            count: visible.count,
            watches: visible.map {
                WatchedRepoDTO(owner: $0.repoOwner, repo: $0.repoName, createdAt: $0.createdAt)
            }))
    }

    // ───────────────────────── Activity + feed ─────────────────────────

    app.get("api", "repos", ":user", ":repo", "activity") { req async throws -> Response in
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }
        try await gateRead(req, user: u, repo: r)
        let limit = max(1, min(200, req.query[Int.self, at: "limit"] ?? 50))
        let entries = await activity.list(user: u, repo: r, limit: limit)
        return try jsonRespSW(RepoActivityDTO(
            user: u, repo: r,
            count: entries.count,
            entries: entries.map(ActivityEntryDTO.from)))
    }

    app.get("api", "users", ":name", "feed") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        let actor = try await requireAuthed(req)
        let isAdmin = (await users.get(actor)?.isAdmin) ?? false
        guard actor == name || isAdmin else {
            throw Abort(.forbidden, reason: "feed is private to its owner")
        }
        if await users.get(name) == nil {
            throw Abort(.notFound, reason: "no such user: '\(name)'")
        }
        let limit = max(1, min(200, req.query[Int.self, at: "limit"] ?? 50))
        let watched = (try? await watches.watchedBy(user: name)) ?? []
        // Merge per-repo activity logs into one stream, newest-first.
        var merged: [(WatchStore.Watch, ActivityStore.Entry)] = []
        for w in watched {
            let entries = await activity.list(user: w.repoOwner, repo: w.repoName, limit: limit)
            for e in entries { merged.append((w, e)) }
        }
        merged.sort { $0.1.createdAt > $1.1.createdAt }
        let trimmed = Array(merged.prefix(limit))
        return try jsonRespSW(FeedDTO(
            user: name,
            count: trimmed.count,
            entries: trimmed.map { (w, e) in
                FeedEntryDTO(
                    owner: w.repoOwner,
                    repo: w.repoName,
                    id: e.id,
                    event: e.event,
                    actor: e.actor,
                    summary: e.summary,
                    createdAt: e.createdAt)
            }))
    }
}

// MARK: - DTOs

private struct StarStatusDTO: Content {
    let user: String
    let repo: String
    let starred: Bool
    let stargazerCount: Int
    let createdAt: Date?
}

private struct StargazerDTO: Content {
    let name: String
    let createdAt: Date
}

private struct StargazerListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let stargazers: [StargazerDTO]
}

private struct StarredRepoDTO: Content {
    let owner: String
    let repo: String
    let createdAt: Date
}

private struct StarredByUserDTO: Content {
    let user: String
    let count: Int
    let stars: [StarredRepoDTO]
}

private struct WatchStatusDTO: Content {
    let user: String
    let repo: String
    let watching: Bool
    let createdAt: Date?
}

private struct WatcherDTO: Content {
    let name: String
    let createdAt: Date
}

private struct WatcherListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let watchers: [WatcherDTO]
}

private struct WatchedRepoDTO: Content {
    let owner: String
    let repo: String
    let createdAt: Date
}

private struct WatchedByUserDTO: Content {
    let user: String
    let count: Int
    let watches: [WatchedRepoDTO]
}

private struct ActivityEntryDTO: Content {
    let id: Int
    let event: String
    let actor: String?
    let summary: String
    let createdAt: Date

    static func from(_ e: ActivityStore.Entry) -> ActivityEntryDTO {
        .init(id: e.id, event: e.event, actor: e.actor, summary: e.summary, createdAt: e.createdAt)
    }
}

private struct RepoActivityDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let entries: [ActivityEntryDTO]
}

private struct FeedEntryDTO: Content {
    let owner: String
    let repo: String
    let id: Int
    let event: String
    let actor: String?
    let summary: String
    let createdAt: Date
}

private struct FeedDTO: Content {
    let user: String
    let count: Int
    let entries: [FeedEntryDTO]
}

private func jsonRespSW<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let resp = Response(status: status)
    resp.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    resp.body = .init(data: data)
    return resp
}
