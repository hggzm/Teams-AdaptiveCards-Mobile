import Foundation
import Vapor

/// Phase 10 wiring: pull-request REST API + FF-merge endpoint.
///
///   GET    /api/repos/:user/:repo/pulls                      (open)
///   GET    /api/repos/:user/:repo/pulls/:number              (open)
///   POST   /api/repos/:user/:repo/pulls                      (auth)
///   PATCH  /api/repos/:user/:repo/pulls/:number              (auth)
///   GET    /api/repos/:user/:repo/pulls/:number/comments     (open)
///   POST   /api/repos/:user/:repo/pulls/:number/comments     (auth)
///   GET    /api/repos/:user/:repo/pulls/:number/merge        (open)  -- merge status probe
///   POST   /api/repos/:user/:repo/pulls/:number/merge        (auth)  -- perform FF merge
///
/// Reads always anon. Writes share the same `GitPushBasicAuth` gate as
/// `git push` and issues. Writer's username is attributed to
/// PullRequest.authorName / Comment.authorName / mergedBy.
func registerPullRequestRoutes(
    _ app: Application,
    store: PullRequestStore,
    pushAuth: GitPushBasicAuth?,
    events: EventSink = DiscardEventSink(),
    access: AccessController? = nil,
    metaStore: RepoMetaStore? = nil,
    reviewStore: PRReviewStore? = nil,
    forks: ForkStore? = nil,
    rootURL: URL? = nil,
    users: UserStore? = nil
) {

    // MARK: - Read

    /// Phase 12 read gate (anon OK on public).
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

    app.get("api", "repos", ":user", ":repo", "pulls") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        try await gateRead(req, user: user, repo: repo)
        let stateRaw = req.query[String.self, at: "state"]?.lowercased()
        let stateFilter: PullRequestStore.State?
        switch stateRaw {
        case nil, "", "all": stateFilter = nil
        case "open":         stateFilter = .open
        case "closed":       stateFilter = .closed
        case "merged":       stateFilter = .merged
        default:
            throw Abort(.badRequest, reason: "state must be open|closed|merged|all")
        }
        let limit = clampPRInt(Int(req.query[String.self, at: "limit"] ?? "") ?? 50, min: 1, max: 200)
        let prs: [PullRequestStore.PullRequest]
        do {
            prs = try await store.list(user: user, repo: repo, state: stateFilter, limit: limit)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try prJSON(PullRequestListDTO(
            user: user, repo: repo,
            state: stateRaw ?? "all",
            count: prs.count,
            pullRequests: prs.map(PullRequestDTO.from)
        ))
    }

    app.get("api", "repos", ":user", ":repo", "pulls", ":number") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        try await gateRead(req, user: user, repo: repo)
        let pr: PullRequestStore.PullRequest
        do {
            pr = try await store.get(user: user, repo: repo, number: n)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try prJSON(PullRequestDTO.from(pr))
    }

    app.get("api", "repos", ":user", ":repo", "pulls", ":number", "comments") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        try await gateRead(req, user: user, repo: repo)
        let comments: [PullRequestStore.Comment]
        do {
            comments = try await store.comments(user: user, repo: repo, number: n)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try prJSON(PRCommentListDTO(
            user: user, repo: repo, prNumber: n,
            count: comments.count,
            comments: comments.map(PRCommentDTO.from)
        ))
    }

    /// Merge-status probe: tells the client whether a POST .../merge
    /// would succeed without actually doing anything.
    app.get("api", "repos", ":user", ":repo", "pulls", ":number", "merge") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        try await gateRead(req, user: user, repo: repo)
        let (status, headOID, baseOID): (PullRequestStore.MergeStatus, String, String)
        do {
            (status, headOID, baseOID) = try await store.mergeStatus(user: user, repo: repo, number: n)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return try prJSON(MergeStatusDTO(
            number: n,
            status: status.rawValue,
            // From v0.0.20 the server attempts a 3-way merge for
            // non-FF cases. The probe is intentionally cheap and does
            // NOT re-run the merge, so .diverged is reported as
            // optimistically mergeable -- the actual POST may still
            // surface a 409 with conflicts.
            mergeable: status == .fastForward || status == .diverged,
            headCommit: headOID.isEmpty ? nil : headOID,
            baseCommit: baseOID.isEmpty ? nil : baseOID
        ))
    }

    // MARK: - Write

    @Sendable
    func requireAuthor(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "PR writes are disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let response = try await pushAuth.gate(req) {
            _ = response
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm=\"giteax\""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required to write pull requests")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write, user: user, repo: repo,
                    scope: "writing pull requests"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    app.post("api", "repos", ":user", ":repo", "pulls") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        let author = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(CreatePullDTO.self)

        // Phase 41: cross-fork PR support. `head` accepts:
        //   "branch"                    -- same-repo (legacy)
        //   "otherOwner:branch"         -- fork in same repo name
        //   "otherOwner/otherRepo:branch" -- fork with renamed repo
        var resolvedHead = body.head
        var headOwner: String? = nil
        var headRepo:  String? = nil
        var headOriginalBranch: String? = nil
        if body.head.contains(":") {
            let parts = body.head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw Abort(.badRequest, reason: "head must be 'branch', 'owner:branch', or 'owner/repo:branch'")
            }
            let originRaw = parts[0]
            let originalBranch = parts[1]
            let parsedOwner: String
            let parsedRepo: String
            if originRaw.contains("/") {
                let oo = originRaw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard oo.count == 2, !oo[0].isEmpty, !oo[1].isEmpty else {
                    throw Abort(.badRequest, reason: "head 'owner/repo' part is malformed")
                }
                parsedOwner = oo[0]; parsedRepo = oo[1]
            } else {
                parsedOwner = originRaw; parsedRepo = repo
            }
            guard RepositoryService.validateSegment(parsedOwner),
                  RepositoryService.validateSegment(parsedRepo),
                  RepositoryService.validateSegment(originalBranch) else {
                throw Abort(.badRequest, reason: "head segments contain illegal characters")
            }
            // Same-owner shorthand collapses to local.
            if parsedOwner == user && parsedRepo == repo {
                resolvedHead = originalBranch
            } else {
                guard let forks, let rootURL else {
                    throw Abort(.serviceUnavailable, reason: "cross-fork PRs disabled (forks subsystem missing)")
                }
                // Lineage check.
                let baseRef = ForkStore.RepoRef(owner: user, repo: repo)
                let headRef = ForkStore.RepoRef(owner: parsedOwner, repo: parsedRepo)
                guard try await forks.sharesFamily(baseRef, headRef) else {
                    throw Abort(.forbidden, reason: "\(parsedOwner)/\(parsedRepo) is not a fork of \(user)/\(repo) (or sibling)")
                }
                // Fetch the fork's branch into the base bare repo as a
                // local mirror branch so the existing merge machinery
                // resolves it as a normal local branch.
                let basePath = rootURL.appendingPathComponent(user).appendingPathComponent("\(repo).git").path
                let headPath = rootURL.appendingPathComponent(parsedOwner).appendingPathComponent("\(parsedRepo).git").path
                guard FileManager.default.fileExists(atPath: headPath) else {
                    throw Abort(.notFound, reason: "head fork repo not on disk: \(parsedOwner)/\(parsedRepo).git")
                }
                let mirrorBranch = "__fork__/\(parsedOwner)/\(parsedRepo)/\(originalBranch)"
                let refspec = "+refs/heads/\(originalBranch):refs/heads/\(mirrorBranch)"
                if let err = runGitFetch(gitDir: basePath, fromRepo: headPath, refspec: refspec) {
                    throw Abort(.internalServerError, reason: "fetch from fork failed: \(err.prefix(400))")
                }
                resolvedHead = mirrorBranch
                headOwner = parsedOwner
                headRepo  = parsedRepo
                headOriginalBranch = originalBranch
            }
        }

        let pr: PullRequestStore.PullRequest
        do {
            pr = try await store.create(
                user: user, repo: repo,
                authorName: author,
                title: body.title,
                body: body.body ?? "",
                headBranch: resolvedHead,
                baseBranch: body.base,
                headOwner: headOwner,
                headRepo:  headRepo,
                headOriginalBranch: headOriginalBranch
            )
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: user, repo: repo, event: "pull_request", payload: [
            "action": "opened",
            "number": pr.number,
            "title": pr.title,
            "authorName": pr.authorName,
            "head": pr.headBranch,
            "base": pr.baseBranch,
            "headCommit": pr.headCommit,
            "baseCommit": pr.baseCommit,
        ])
        return try prJSON(PullRequestDTO.from(pr), status: .created)
    }

    app.patch("api", "repos", ":user", ":repo", "pulls", ":number") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        _ = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(UpdatePullDTO.self)
        var stateEnum: PullRequestStore.State? = nil
        if let raw = body.state {
            guard let parsed = PullRequestStore.State(rawValue: raw) else {
                throw Abort(.badRequest, reason: "state must be open|closed (use POST /merge for merged)")
            }
            stateEnum = parsed
        }
        let pr: PullRequestStore.PullRequest
        do {
            pr = try await store.update(
                user: user, repo: repo, number: n,
                title: body.title, body: body.body, state: stateEnum
            )
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: user, repo: repo, event: "pull_request", payload: [
            "action": "edited",
            "number": pr.number,
            "title": pr.title,
            "state": pr.state.rawValue,
        ])
        return try prJSON(PullRequestDTO.from(pr))
    }

    app.post("api", "repos", ":user", ":repo", "pulls", ":number", "comments") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        let author = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(CreateCommentBodyDTO.self)
        // Phase 50: locked PRs reject comments unless requester is admin on the repo.
        if (try? await store.isLocked(user: user, repo: repo, number: n)) == true {
            var isAdmin = false
            if let access {
                do {
                    try await access.require(
                        AuthIdentity(name: author, isGlobalAdmin: false),
                        atLeast: .admin, user: user, repo: repo,
                        scope: "commenting on locked PR"
                    )
                    isAdmin = true
                } catch { isAdmin = false }
            }
            if !isAdmin {
                throw Abort(HTTPResponseStatus(statusCode: 423, reasonPhrase: "Locked"),
                            reason: "pull request #\(n) is locked")
            }
        }
        let comment: PullRequestStore.Comment
        do {
            comment = try await store.addComment(
                user: user, repo: repo, number: n,
                authorName: author, body: body.body
            )
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: user, repo: repo, event: "pull_request_comment", payload: [
            "action": "created",
            "prNumber": comment.prNumber,
            "commentID": comment.id,
            "authorName": comment.authorName,
        ])
        return try prJSON(PRCommentDTO.from(comment), status: .created)
    }

    app.post("api", "repos", ":user", ":repo", "pulls", ":number", "merge") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        let author = try await requireAuthor(req, user: user, repo: repo)

        // Phase 36: enforce requiredApprovals before invoking the merge.
        if let metaStore, let reviewStore {
            let required: Int
            do {
                let meta = try await metaStore.get(user: user, repo: repo)
                required = meta.requiredApprovals ?? 0
            } catch {
                required = 0
            }
            if required > 0 {
                let pr: PullRequestStore.PullRequest
                do {
                    pr = try await store.get(user: user, repo: repo, number: n)
                } catch let e as PullRequestStore.StoreError {
                    throw Abort(e.status, reason: e.reason)
                }
                let approvers = (try? await reviewStore.approvers(
                    user: user, repo: repo, prNumber: n, prAuthor: pr.authorName
                )) ?? []
                if approvers.count < required {
                    let dto = InsufficientApprovalsDTO(
                        number: n,
                        requiredApprovals: required,
                        haveApprovals: approvers.count,
                        approvers: approvers,
                        reason: "needs at least \(required) approval(s) from non-author reviewers; have \(approvers.count)"
                    )
                    let resp = Response(status: .unprocessableEntity)
                    try resp.content.encode(dto, as: .json)
                    return resp
                }
            }
        }

        let pr: PullRequestStore.PullRequest
        do {
            pr = try await store.merge(user: user, repo: repo, number: n, mergedBy: author)
        } catch let storeErr as PullRequestStore.StoreError {
            // Conflict path: surface the structured payload directly
            // so clients can render which paths to resolve.
            if case .mergeConflict(let conflicts) = storeErr {
                let dto = MergeConflictDTO(
                    number: n,
                    reason: "3-way merge produced conflicts",
                    conflicts: conflicts.map(MergeConflictEntryDTO.from)
                )
                return try prJSON(dto, status: .conflict)
            }
            throw Abort(storeErr.status, reason: storeErr.reason)
        }
        await events.fire(user: user, repo: repo, event: "pull_request", payload: [
            "action": "merged",
            "number": pr.number,
            "title": pr.title,
            "head": pr.headBranch,
            "base": pr.baseBranch,
            "mergedBy": pr.mergedBy ?? "",
            "mergeCommit": pr.mergeCommit ?? "",
        ])
        return try prJSON(PullRequestDTO.from(pr))
    }

    // Phase 50: lock + unlock PR conversation. Both require write+.
    app.post("api", "repos", ":user", ":repo", "pulls", ":number", "lock") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        _ = try await requireAuthor(req, user: user, repo: repo)
        do {
            let pr = try await store.setLocked(user: user, repo: repo, number: n, locked: true)
            return try prJSON(PullRequestDTO.from(pr), status: .ok)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    app.delete("api", "repos", ":user", ":repo", "pulls", ":number", "lock") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        _ = try await requireAuthor(req, user: user, repo: repo)
        do {
            _ = try await store.setLocked(user: user, repo: repo, number: n, locked: false)
            return Response(status: .noContent)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    // Phase 51: replace PR assignees (write+). Body: {assignees:[String]}.
    app.put("api", "repos", ":user", ":repo", "pulls", ":number", "assignees") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        _ = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(SetPRAssigneesDTO.self)
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
            let pr = try await store.setAssignees(user: user, repo: repo, number: n, assignees: body.assignees)
            return try prJSON(PullRequestDTO.from(pr), status: .ok)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    // Phase 52: emoji reactions on PRs.
    app.get("api", "repos", ":user", ":repo", "pulls", ":number", "reactions") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        try await gateRead(req, user: user, repo: repo)
        do {
            let rs = try await store.reactions(user: user, repo: repo, number: n)
            return try prJSON(PRReactionListDTO(user: user, repo: repo, prNumber: n, count: rs.count, reactions: rs.map(PRReactionDTO.from)))
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    app.post("api", "repos", ":user", ":repo", "pulls", ":number", "reactions") { req async throws -> Response in
        let (user, repo, n) = try prRouteParams(req)
        let author = try await requireAuthor(req, user: user, repo: repo)
        let body = try req.content.decode(CreatePRReactionDTO.self)
        do {
            let r = try await store.addReaction(user: user, repo: repo, number: n, userName: author, content: body.content)
            return try prJSON(PRReactionDTO.from(r), status: .created)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    app.delete("api", "repos", ":user", ":repo", "pulls", ":number", "reactions", ":reactionID") { req async throws -> Response in
        guard let user = req.parameters.get("user"), let repo = req.parameters.get("repo"), let n = req.parameters.get("number", as: Int.self), let rid = req.parameters.get("reactionID", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :user, :repo, :number or :reactionID") }
        let author = try await requireAuthor(req, user: user, repo: repo)
        let existing: PullRequestStore.Reaction
        do {
            let all = try await store.reactions(user: user, repo: repo, number: n)
            guard let found = all.first(where: { $0.id == rid }) else { throw Abort(.notFound, reason: "reaction #\(rid) not found") }
            existing = found
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        if existing.userName != author {
            if let access = access {
                let identity = try await access.identify(req)
                _ = try await access.require(identity, atLeast: .admin, user: user, repo: repo, scope: "deleting another user's PR reaction")
            } else {
                throw Abort(.forbidden, reason: "only the reaction owner can delete it")
            }
        }
        do {
            _ = try await store.removeReaction(user: user, repo: repo, number: n, reactionID: rid)
            return Response(status: .noContent)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
}

// MARK: - DTOs

private struct CreatePullDTO: Content {
    let title: String
    let body: String?
    let head: String
    let base: String
}

private struct UpdatePullDTO: Content {
    let title: String?
    let body: String?
    let state: String?
}

private struct CreateCommentBodyDTO: Content {
    let body: String
}

private struct SetPRAssigneesDTO: Content {
    let assignees: [String]
}

private struct CreatePRReactionDTO: Content {
    let content: String
}

private struct PRReactionDTO: Content {
    let id: Int
    let prNumber: Int
    let userName: String
    let content: String
    let createdAt: Date
    static func from(_ r: PullRequestStore.Reaction) -> PRReactionDTO {
        PRReactionDTO(id: r.id, prNumber: r.prNumber, userName: r.userName, content: r.content, createdAt: r.createdAt)
    }
}

private struct PRReactionListDTO: Content {
    let user: String
    let repo: String
    let prNumber: Int
    let count: Int
    let reactions: [PRReactionDTO]
}

private struct PullRequestDTO: Content {
    let number: Int
    let title: String
    let body: String
    let authorName: String
    let head: String
    let base: String
    let headOwner: String?
    let headRepo: String?
    let headOriginalBranch: String?
    let headCommit: String
    let baseCommit: String
    let createdAt: Date
    let updatedAt: Date
    let state: String
    let mergedAt: Date?
    let mergedBy: String?
    let mergeCommit: String?
    let commentCount: Int
    let locked: Bool
    let assignees: [String]

    static func from(_ p: PullRequestStore.PullRequest) -> PullRequestDTO {
        PullRequestDTO(
            number: p.number,
            title: p.title,
            body: p.body,
            authorName: p.authorName,
            head: p.headBranch,
            base: p.baseBranch,
            headOwner: p.headOwner,
            headRepo: p.headRepo,
            headOriginalBranch: p.headOriginalBranch,
            headCommit: p.headCommit,
            baseCommit: p.baseCommit,
            createdAt: p.createdAt,
            updatedAt: p.updatedAt,
            state: p.state.rawValue,
            mergedAt: p.mergedAt,
            mergedBy: p.mergedBy,
            mergeCommit: p.mergeCommit,
            commentCount: p.commentCount,
            locked: p.locked == true,
            assignees: p.assignees ?? []
        )
    }
}

private struct PullRequestListDTO: Content {
    let user: String
    let repo: String
    let state: String
    let count: Int
    let pullRequests: [PullRequestDTO]
}

private struct PRCommentDTO: Content {
    let id: Int
    let prNumber: Int
    let authorName: String
    let body: String
    let createdAt: Date

    static func from(_ c: PullRequestStore.Comment) -> PRCommentDTO {
        PRCommentDTO(
            id: c.id,
            prNumber: c.prNumber,
            authorName: c.authorName,
            body: c.body,
            createdAt: c.createdAt
        )
    }
}

private struct PRCommentListDTO: Content {
    let user: String
    let repo: String
    let prNumber: Int
    let count: Int
    let comments: [PRCommentDTO]
}

private struct MergeStatusDTO: Content {
    let number: Int
    let status: String
    let mergeable: Bool
    let headCommit: String?
    let baseCommit: String?
}

// 3-way merge conflict response (HTTP 409). Mirrors
// PullRequestStore.ConflictEntry; `oid` of "" represents a missing
// side (e.g. add/add has no ancestor; delete/modify has no ours OR
// no theirs).
private struct MergeConflictDTO: Content {
    let number: Int
    let reason: String
    let conflicts: [MergeConflictEntryDTO]
}

// Phase 36: returned with HTTP 422 when settings.requiredApprovals
// blocks a merge.
private struct InsufficientApprovalsDTO: Content {
    let number: Int
    let requiredApprovals: Int
    let haveApprovals: Int
    let approvers: [String]
    let reason: String
}

private struct MergeConflictEntryDTO: Content {
    let path: String
    let ancestor: MergeConflictSideDTO?
    let ours: MergeConflictSideDTO?
    let theirs: MergeConflictSideDTO?

    static func from(_ c: PullRequestStore.ConflictEntry) -> MergeConflictEntryDTO {
        MergeConflictEntryDTO(
            path: c.path,
            ancestor: c.ancestor.map(MergeConflictSideDTO.from),
            ours: c.ours.map(MergeConflictSideDTO.from),
            theirs: c.theirs.map(MergeConflictSideDTO.from)
        )
    }
}

private struct MergeConflictSideDTO: Content {
    let oid: String
    let path: String
    let mode: UInt32

    static func from(_ s: PullRequestStore.ConflictSide) -> MergeConflictSideDTO {
        MergeConflictSideDTO(oid: s.oid, path: s.path, mode: s.mode)
    }
}

// MARK: - Helpers

private func prRouteParams(_ req: Request) throws -> (String, String, Int) {
    guard let user = req.parameters.get("user"),
          let repo = req.parameters.get("repo"),
          let n = req.parameters.get("number", as: Int.self)
    else { throw Abort(.badRequest, reason: "missing :user, :repo or :number") }
    return (user, repo, n)
}

private func prJSON<E: Encodable>(_ value: E, status: HTTPResponseStatus = .ok) throws -> Response {
    let r = Response(status: status)
    try r.content.encode(value, as: .json)
    return r
}

private func clampPRInt(_ x: Int, min lo: Int, max hi: Int) -> Int {
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}

// MARK: - Phase 41 git-fetch helper (cross-fork PR open)

/// Run git --git-dir=<gitDir> fetch <fromRepo> <refspec>. Returns
/// nil on success, or stderr text on failure. Used by the cross-fork
/// PR open path to mirror a fork's branch into the base bare repo.
@Sendable
func runGitFetch(gitDir: String, fromRepo: String, refspec: String) -> String? {
    let p = Process()
    guard let gitPath = whichForPR("git") else {
        return "git executable not found in PATH"
    }
    p.executableURL = URL(fileURLWithPath: gitPath)
    p.arguments = ["--git-dir=\(gitDir)", "fetch", "--quiet", fromRepo, refspec]
    let errPipe = Pipe()
    p.standardOutput = Pipe()
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return "could not invoke git: \(error)"
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "git fetch failed (exit \(p.terminationStatus))"
    }
    return nil
}

@Sendable
private func whichForPR(_ exe: String) -> String? {
    #if os(Windows)
    let sep: Character = ";"
    let exts = [".exe", ".cmd", ".bat", ""]
    #else
    let sep: Character = ":"
    let exts = [""]
    #endif
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    let dirs = path.split(separator: sep)
    for ext in exts {
        for dir in dirs {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(exe + ext)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
    }
    return nil
}
