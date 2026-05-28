import Foundation
import Vapor

/// Phase 9 wiring: issue + comment + label REST API.
///
///   POST   /api/repos/:user/:repo/issues                            (auth)  create
///   GET    /api/repos/:user/:repo/issues?state=open&label=bug       (open)  list
///   GET    /api/repos/:user/:repo/issues/:number                    (open)  get
///   PATCH  /api/repos/:user/:repo/issues/:number                    (auth)  update
///   POST   /api/repos/:user/:repo/issues/:number/comments           (auth)  add comment
///   GET    /api/repos/:user/:repo/issues/:number/comments           (open)  list comments
///
/// Reads (GET) are always anonymous to mirror Gitea's public-by-default
/// posture. Writes (POST/PATCH) require HTTP Basic auth -- the same
/// `GitPushBasicAuth` gate used by `git push`, so a single set of
/// credentials covers both code push and issue activity.
///
/// All writes attribute the request's authed user to the
/// Issue/Comment.authorName field. When `pushAuth == nil` (push fully
/// disabled at the env-flag level) writes are also disabled and
/// return 403. This is intentional: the server operator opting out of
/// push is opting out of all writes.
func registerIssueRoutes(
    _ app: Application,
    store: IssueStore,
    pushAuth: GitPushBasicAuth?,
    events: EventSink = DiscardEventSink(),
    access: AccessController? = nil,
    milestones: MilestoneStore? = nil,
    users: UserStore? = nil
) {
    let pool = app.threadPool

    /// Hop a blocking IssueStore call off the event loop. The store is
    /// actor-isolated so we await it normally; the runIfActive wrap is
    /// for filesystem I/O (`Data.write(to:)` / `Data(contentsOf:)`)
    /// which can briefly block on a slow disk.
    func runIssue<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await work()
    }

    /// Phase 12 read gate: anon for public repos, authed for internal,
    /// collaborators for private. Falls through when access is nil
    /// (legacy / tests).
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

    // MARK: - Read routes (open)

    app.get("api", "repos", ":user", ":repo", "issues") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        try await gateRead(req, user: user, repo: repo)
        let stateRaw = req.query[String.self, at: "state"]?.lowercased()
        let stateFilter: IssueStore.State?
        switch stateRaw {
        case nil, "", "all": stateFilter = nil
        case "open":         stateFilter = .open
        case "closed":       stateFilter = .closed
        default:
            throw Abort(.badRequest, reason: "state must be open|closed|all")
        }
        let label = req.query[String.self, at: "label"]
        let milestoneFilter = req.query[Int.self, at: "milestone"]
        let limit = clampInt(Int(req.query[String.self, at: "limit"] ?? "") ?? 50, min: 1, max: 200)
        let issues: [IssueStore.Issue]
        do {
            issues = try await store.list(user: user, repo: repo, state: stateFilter, label: label, milestone: milestoneFilter, limit: limit)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(IssueListDTO(
            user: user, repo: repo,
            state: stateRaw ?? "all",
            label: label,
            milestone: milestoneFilter,
            count: issues.count,
            issues: issues.map(IssueDTO.from)
        ))
    }

    app.get("api", "repos", ":user", ":repo", "issues", ":number") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        try await gateRead(req, user: user, repo: repo)
        let issue: IssueStore.Issue
        do {
            issue = try await store.get(user: user, repo: repo, number: n)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(IssueDTO.from(issue))
    }

    app.get("api", "repos", ":user", ":repo", "issues", ":number", "comments") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        try await gateRead(req, user: user, repo: repo)
        let comments: [IssueStore.Comment]
        do {
            comments = try await store.comments(user: user, repo: repo, number: n)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try jsonResp(CommentListDTO(
            user: user, repo: repo, issueNumber: n,
            count: comments.count,
            comments: comments.map(CommentDTO.from)
        ))
    }

    // MARK: - Write routes (auth)

    /// All writes share the same HTTP-Basic-against-UserStore check as
    /// `git push`. Without a push-auth gate, writes are 403.
    @Sendable
    func requireAuthor(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "issue writes are disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let response = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            _ = response  // silence unused
            throw Abort(.unauthorized, headers: headers, reason: "authentication required to write issues")
        }
        // `gate(_:)` stashed the authed user name on req.storage.
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        // Phase 12: check per-repo write permission.
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write, user: user, repo: repo,
                    scope: "writing issues"
                )
            } catch let e as AccessController.AccessError {
                // requireRead() above will already have run on read paths;
                // a write attempt by an authed user without write perms
                // here is a clean 403.
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    app.post("api", "repos", ":user", ":repo", "issues") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        let author = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(CreateIssueDTO.self)
        // Validate milestone reference if provided.
        if let m = body.milestone, let milestones {
            let exists = await milestones.exists(user: user, repo: repo, number: m)
            if !exists { throw Abort(.badRequest, reason: "milestone #\(m) not found") }
        }
        let issue: IssueStore.Issue
        do {
            issue = try await store.create(
                user: user, repo: repo,
                authorName: author,
                title: body.title,
                body: body.body ?? "",
                labels: body.labels ?? [],
                milestone: body.milestone
            )
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: user, repo: repo, event: "issue", payload: [
            "action": "opened",
            "number": issue.number,
            "title": issue.title,
            "authorName": issue.authorName,
        ])
        return try jsonResp(IssueDTO.from(issue), status: .created)
    }

    app.patch("api", "repos", ":user", ":repo", "issues", ":number") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        _ = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(UpdateIssueDTO.self)
        var stateEnum: IssueStore.State? = nil
        if let raw = body.state {
            guard let parsed = IssueStore.State(rawValue: raw) else {
                throw Abort(.badRequest, reason: "state must be open|closed")
            }
            stateEnum = parsed
        }
        // Double-optional for milestone: absent key = leave alone;
        // {"milestone": null} = clear; {"milestone": N} = set.
        let milestoneArg: Int??
        if body.milestonePresent {
            if let m = body.milestone, let milestones {
                let exists = await milestones.exists(user: user, repo: repo, number: m)
                if !exists { throw Abort(.badRequest, reason: "milestone #\(m) not found") }
            }
            milestoneArg = .some(body.milestone)
        } else {
            milestoneArg = nil
        }
        let issue: IssueStore.Issue
        do {
            issue = try await store.update(
                user: user, repo: repo, number: n,
                title: body.title,
                body: body.body,
                state: stateEnum,
                labels: body.labels,
                milestone: milestoneArg
            )
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: user, repo: repo, event: "issue", payload: [
            "action": "edited",
            "number": issue.number,
            "title": issue.title,
            "state": issue.state.rawValue,
        ])
        return try jsonResp(IssueDTO.from(issue))
    }

    app.post("api", "repos", ":user", ":repo", "issues", ":number", "comments") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        let author = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(CreateCommentDTO.self)
        // Phase 50: locked issues reject comments unless requester is admin on the repo.
        if (try? await store.isLocked(user: user, repo: repo, number: n)) == true {
            var isAdmin = false
            if let access {
                do {
                    try await access.require(
                        AuthIdentity(name: author, isGlobalAdmin: false),
                        atLeast: .admin, user: user, repo: repo,
                        scope: "commenting on locked issue"
                    )
                    isAdmin = true
                } catch { isAdmin = false }
            }
            if !isAdmin {
                throw Abort(HTTPResponseStatus(statusCode: 423, reasonPhrase: "Locked"),
                            reason: "issue #\(n) is locked")
            }
        }
        let comment: IssueStore.Comment
        do {
            comment = try await store.addComment(
                user: user, repo: repo, number: n,
                authorName: author,
                body: body.body
            )
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: user, repo: repo, event: "issue_comment", payload: [
            "action": "created",
            "issueNumber": comment.issueNumber,
            "commentID": comment.id,
            "authorName": comment.authorName,
        ])
        return try jsonResp(CommentDTO.from(comment), status: .created)
    }

    // Phase 50: lock + unlock issue conversation. Both require write+.
    app.post("api", "repos", ":user", ":repo", "issues", ":number", "lock") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        _ = try await requireAuthor(req, user: user, repo: repo)
        do {
            let issue = try await store.setLocked(user: user, repo: repo, number: n, locked: true)
            return try jsonResp(IssueDTO.from(issue), status: .ok)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    app.delete("api", "repos", ":user", ":repo", "issues", ":number", "lock") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        _ = try await requireAuthor(req, user: user, repo: repo)
        do {
            _ = try await store.setLocked(user: user, repo: repo, number: n, locked: false)
            return Response(status: .noContent)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    // Phase 51: replace issue assignees (write+). Body: {assignees:[String]}.
    // Each name must exist in UserStore. Empty array clears assignment.
    app.put("api", "repos", ":user", ":repo", "issues", ":number", "assignees") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        _ = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(SetAssigneesDTO.self)
        // Existence check (when UserStore is wired): unknown names -> 400.
        if let userStore = users {
            for name in body.assignees {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if await userStore.get(trimmed) == nil {
                    throw Abort(.badRequest, reason: "unknown assignee: \(trimmed)")
                }
            }
        }
        do {
            let issue = try await store.setAssignees(user: user, repo: repo, number: n, assignees: body.assignees)
            return try jsonResp(IssueDTO.from(issue), status: .ok)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    // Phase 52: emoji reactions on issues.
    // GET /api/repos/:u/:r/issues/:n/reactions  (public via gateRead)
    app.get("api", "repos", ":user", ":repo", "issues", ":number", "reactions") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        try await gateRead(req, user: user, repo: repo)
        do {
            let rs = try await store.reactions(user: user, repo: repo, number: n)
            return try jsonResp(ReactionListDTO(
                user: user, repo: repo, issueNumber: n, count: rs.count,
                reactions: rs.map(ReactionDTO.from)
            ))
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    // POST .../reactions  (write+); body {content:String}
    app.post("api", "repos", ":user", ":repo", "issues", ":number", "reactions") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
        let author = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(CreateReactionDTO.self)
        do {
            let r = try await store.addReaction(user: user, repo: repo, number: n, userName: author, content: body.content)
            return try jsonResp(ReactionDTO.from(r), status: .created)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    // DELETE .../reactions/:reactionID (write+; reaction owner OR repo admin)
    app.delete("api", "repos", ":user", ":repo", "issues", ":number", "reactions", ":reactionID") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let n = req.parameters.get("number", as: Int.self),
              let rid = req.parameters.get("reactionID", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo, :number or :reactionID") }
        let author = try await requireAuthor(req, user: user, repo: repo)
        // Peek the reaction to enforce owner-or-admin.
        let existing: IssueStore.Reaction
        do {
            let all = try await store.reactions(user: user, repo: repo, number: n)
            guard let found = all.first(where: { $0.id == rid }) else {
                throw Abort(.notFound, reason: "reaction #\(rid) not found")
            }
            existing = found
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        if existing.userName != author {
            // Not the owner → require admin on the repo.
            if let access = access {
                let identity = try await access.identify(req)
                _ = try await access.require(identity, atLeast: .admin, user: user, repo: repo, scope: "deleting another user's reaction")
            } else {
                throw Abort(.forbidden, reason: "only the reaction owner can delete it")
            }
        }
        do {
            _ = try await store.removeReaction(user: user, repo: repo, number: n, reactionID: rid)
            return Response(status: .noContent)
        } catch let e as IssueStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
}

// MARK: - DTOs

private struct CreateIssueDTO: Content {
    let title: String
    let body: String?
    let labels: [String]?
    let milestone: Int?
}

private struct UpdateIssueDTO: Content {
    let title: String?
    let body: String?
    let state: String?
    let labels: [String]?
    let milestone: Int?
    /// Tracks whether the inbound JSON contained the `milestone` key at
    /// all. Required so we can distinguish "don't touch" (key absent)
    /// from "clear assignment" (key present, value null).
    let milestonePresent: Bool

    enum CodingKeys: String, CodingKey { case title, body, state, labels, milestone }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title  = try c.decodeIfPresent(String.self,   forKey: .title)
        body   = try c.decodeIfPresent(String.self,   forKey: .body)
        state  = try c.decodeIfPresent(String.self,   forKey: .state)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        milestonePresent = c.contains(.milestone)
        milestone = try c.decodeIfPresent(Int.self, forKey: .milestone)
    }
}

private struct CreateCommentDTO: Content {
    let body: String
}

private struct SetAssigneesDTO: Content {
    let assignees: [String]
}

private struct CreateReactionDTO: Content {
    let content: String
}

private struct ReactionDTO: Content {
    let id: Int
    let issueNumber: Int
    let userName: String
    let content: String
    let createdAt: Date

    static func from(_ r: IssueStore.Reaction) -> ReactionDTO {
        ReactionDTO(
            id: r.id,
            issueNumber: r.issueNumber,
            userName: r.userName,
            content: r.content,
            createdAt: r.createdAt
        )
    }
}

private struct ReactionListDTO: Content {
    let user: String
    let repo: String
    let issueNumber: Int
    let count: Int
    let reactions: [ReactionDTO]
}

private struct IssueDTO: Content {
    let number: Int
    let title: String
    let body: String
    let authorName: String
    let createdAt: Date
    let updatedAt: Date
    let state: String
    let labels: [String]
    let commentCount: Int
    let milestone: Int?
    let locked: Bool
    let assignees: [String]

    static func from(_ i: IssueStore.Issue) -> IssueDTO {
        IssueDTO(
            number: i.number,
            title: i.title,
            body: i.body,
            authorName: i.authorName,
            createdAt: i.createdAt,
            updatedAt: i.updatedAt,
            state: i.state.rawValue,
            labels: i.labels,
            commentCount: i.commentCount,
            milestone: i.milestone,
            locked: i.locked == true,
            assignees: i.assignees ?? []
        )
    }
}

private struct CommentDTO: Content {
    let id: Int
    let issueNumber: Int
    let authorName: String
    let body: String
    let createdAt: Date

    static func from(_ c: IssueStore.Comment) -> CommentDTO {
        CommentDTO(
            id: c.id,
            issueNumber: c.issueNumber,
            authorName: c.authorName,
            body: c.body,
            createdAt: c.createdAt
        )
    }
}

private struct IssueListDTO: Content {
    let user: String
    let repo: String
    let state: String
    let label: String?
    let milestone: Int?
    let count: Int
    let issues: [IssueDTO]
}

private struct CommentListDTO: Content {
    let user: String
    let repo: String
    let issueNumber: Int
    let count: Int
    let comments: [CommentDTO]
}

// MARK: - Shared helpers

private func jsonResp<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let r = Response(status: status)
    try r.content.encode(value, as: .json)
    return r
}

private func clampInt(_ x: Int, min lo: Int, max hi: Int) -> Int {
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}
