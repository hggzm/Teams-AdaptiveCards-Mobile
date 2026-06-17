import Foundation
import Vapor

/// Phase 36: PR review approvals.
///
///   GET    /api/repos/:user/:repo/pulls/:number/reviews              (read)
///   POST   /api/repos/:user/:repo/pulls/:number/reviews              (write+)
///          body: { state: "approved"|"requested_changes"|"commented", body? }
///
/// `requiredApprovals` is set on per-repo settings (see Phase 12).
/// When > 0, the PR merge route counts distinct reviewers whose
/// latest review state is `approved` (excluding the PR author) and
/// returns 422 with a structured payload if the count is below the
/// configured threshold. Reviews fire the `pull_request_review`
/// webhook event on every POST.
func registerPRReviewRoutes(
    _ app: Application,
    store: PRReviewStore,
    prStore: PullRequestStore,
    pushAuth: GitPushBasicAuth?,
    events: EventSink = DiscardEventSink(),
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
    func requireAuthor(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "PR reviews disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm=\"giteax\""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required to post a review")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write, user: user, repo: repo,
                    scope: "posting PR reviews"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    @Sendable
    func params(_ req: Request) throws -> (String, String, Int) {
        guard let u = req.parameters.get("user"),
              let r = req.parameters.get("repo"),
              let nStr = req.parameters.get("number"),
              let n = Int(nStr)
        else { throw Abort(.badRequest, reason: "missing :user/:repo/:number") }
        return (u, r, n)
    }

    app.get("api", "repos", ":user", ":repo", "pulls", ":number", "reviews") { req async throws -> Response in
        let (u, r, n) = try params(req)
        try await gateRead(req, user: u, repo: r)
        // Confirm PR exists (for clean 404s).
        do {
            _ = try await prStore.get(user: u, repo: r, number: n)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let pr = try await prStore.get(user: u, repo: r, number: n)
        let list: [PRReviewStore.Review]
        let approvers: [String]
        do {
            list = try await store.list(user: u, repo: r, prNumber: n)
            approvers = try await store.approvers(user: u, repo: r, prNumber: n, prAuthor: pr.authorName)
        } catch let e as PRReviewStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let dto = ReviewListDTO(
            user: u, repo: r, prNumber: n,
            count: list.count,
            approverCount: approvers.count,
            approvers: approvers,
            reviews: list.map(ReviewDTO.from)
        )
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.post("api", "repos", ":user", ":repo", "pulls", ":number", "reviews") { req async throws -> Response in
        let (u, r, n) = try params(req)
        let reviewer = try await requireAuthor(req, user: u, repo: r)
        // PR must exist + be open.
        let pr: PullRequestStore.PullRequest
        do {
            pr = try await prStore.get(user: u, repo: r, number: n)
        } catch let e as PullRequestStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        guard pr.state == .open else {
            throw Abort(.conflict, reason: "cannot review PR in state '\(pr.state.rawValue)'")
        }
        let body = try req.content.decode(CreateReviewDTO.self)
        guard let state = PRReviewStore.State(rawValue: body.state) else {
            throw Abort(.badRequest, reason: "state must be approved|requested_changes|commented")
        }
        let review: PRReviewStore.Review
        do {
            review = try await store.add(
                user: u, repo: r, prNumber: n,
                reviewer: reviewer, state: state, body: body.body ?? ""
            )
        } catch let e as PRReviewStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        await events.fire(user: u, repo: r, event: "pull_request_review", payload: [
            "action": "submitted",
            "number": n,
            "reviewID": review.id,
            "reviewer": reviewer,
            "state": state.rawValue,
        ])
        let resp = Response(status: .created)
        try resp.content.encode(ReviewDTO.from(review), as: .json)
        return resp
    }

    // MARK: - Phase 53: line-anchored review comments

    app.get("api", "repos", ":user", ":repo", "pulls", ":number", "reviews", ":reviewID", "comments") { req async throws -> Response in
        let (u, r, n) = try params(req)
        guard let rid = req.parameters.get("reviewID", as: Int.self) else {
            throw Abort(.badRequest, reason: "missing :reviewID")
        }
        try await gateRead(req, user: u, repo: r)
        // PR must exist (clean 404).
        do { _ = try await prStore.get(user: u, repo: r, number: n) }
        catch let e as PullRequestStore.StoreError { throw Abort(e.status, reason: e.reason) }
        let list: [PRReviewStore.ReviewComment]
        do {
            list = try await store.comments(user: u, repo: r, reviewID: rid)
        } catch let e as PRReviewStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        // Confirm the review actually belongs to this PR.
        if let first = list.first, first.prNumber != n {
            throw Abort(.notFound, reason: "review #\(rid) does not belong to PR #\(n)")
        }
        let resp = Response(status: .ok)
        try resp.content.encode(ReviewCommentListDTO(
            user: u, repo: r, prNumber: n, reviewID: rid,
            count: list.count, comments: list.map(ReviewCommentDTO.from)
        ), as: .json)
        return resp
    }

    app.post("api", "repos", ":user", ":repo", "pulls", ":number", "reviews", ":reviewID", "comments") { req async throws -> Response in
        let (u, r, n) = try params(req)
        guard let rid = req.parameters.get("reviewID", as: Int.self) else {
            throw Abort(.badRequest, reason: "missing :reviewID")
        }
        let author = try await requireAuthor(req, user: u, repo: r)
        // PR + review consistency check: peek review's PR.
        let existing: [PRReviewStore.ReviewComment]
        do {
            _ = try await prStore.get(user: u, repo: r, number: n)
            existing = try await store.comments(user: u, repo: r, reviewID: rid)
        } catch let e as PullRequestStore.StoreError { throw Abort(e.status, reason: e.reason) }
        catch let e as PRReviewStore.StoreError { throw Abort(e.status, reason: e.reason) }
        // existing[0] is from the same reviewID; alternatively check against PR via store.list, but keep cheap.
        if let first = existing.first, first.prNumber != n {
            throw Abort(.notFound, reason: "review #\(rid) does not belong to PR #\(n)")
        }
        let body = try req.content.decode(CreateReviewCommentDTO.self)
        let c: PRReviewStore.ReviewComment
        do {
            c = try await store.addComment(
                user: u, repo: r, reviewID: rid, author: author,
                path: body.path, line: body.line, body: body.body
            )
        } catch let e as PRReviewStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        // After insert, cross-check that the review belongs to this PR.
        if c.prNumber != n {
            throw Abort(.notFound, reason: "review #\(rid) does not belong to PR #\(n)")
        }
        let resp = Response(status: .created)
        try resp.content.encode(ReviewCommentDTO.from(c), as: .json)
        return resp
    }

    app.delete("api", "repos", ":user", ":repo", "pulls", ":number", "reviews", ":reviewID", "comments", ":commentID") { req async throws -> Response in
        let (u, r, n) = try params(req)
        guard let rid = req.parameters.get("reviewID", as: Int.self),
              let cid = req.parameters.get("commentID", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :reviewID or :commentID") }
        let actor_ = try await requireAuthor(req, user: u, repo: r)
        let all: [PRReviewStore.ReviewComment]
        do {
            _ = try await prStore.get(user: u, repo: r, number: n)
            all = try await store.comments(user: u, repo: r, reviewID: rid)
        } catch let e as PullRequestStore.StoreError { throw Abort(e.status, reason: e.reason) }
        catch let e as PRReviewStore.StoreError { throw Abort(e.status, reason: e.reason) }
        guard let existing = all.first(where: { $0.id == cid }) else {
            throw Abort(.notFound, reason: "review-comment #\(cid) not found")
        }
        if existing.prNumber != n {
            throw Abort(.notFound, reason: "review #\(rid) does not belong to PR #\(n)")
        }
        if existing.author != actor_ {
            if let access = access {
                let identity = await access.identify(req)
                do {
                    try await access.require(identity, atLeast: .admin, user: u, repo: r, scope: "deleting another user's review comment")
                } catch let e as AccessController.AccessError {
                    throw Abort(e.status, headers: e.headers, reason: e.reason)
                }
            } else {
                throw Abort(.forbidden, reason: "only the comment author can delete it")
            }
        }
        do {
            _ = try await store.removeComment(user: u, repo: r, reviewID: rid, commentID: cid)
        } catch let e as PRReviewStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }
}

// MARK: - DTOs

private struct CreateReviewDTO: Content {
    let state: String
    let body: String?
}

private struct ReviewDTO: Content {
    let id: Int
    let prNumber: Int
    let reviewer: String
    let state: String
    let body: String
    let createdAt: Date

    static func from(_ r: PRReviewStore.Review) -> ReviewDTO {
        ReviewDTO(
            id: r.id, prNumber: r.prNumber, reviewer: r.reviewer,
            state: r.state.rawValue, body: r.body, createdAt: r.createdAt
        )
    }
}

private struct ReviewListDTO: Content {
    let user: String
    let repo: String
    let prNumber: Int
    let count: Int
    let approverCount: Int
    let approvers: [String]
    let reviews: [ReviewDTO]
}

// MARK: - Phase 53 DTOs

private struct CreateReviewCommentDTO: Content {
    let path: String?
    let line: Int?
    let body: String
}

private struct ReviewCommentDTO: Content {
    let id: Int
    let reviewID: Int
    let prNumber: Int
    let path: String?
    let line: Int?
    let body: String
    let author: String
    let createdAt: Date

    static func from(_ c: PRReviewStore.ReviewComment) -> ReviewCommentDTO {
        ReviewCommentDTO(
            id: c.id, reviewID: c.reviewID, prNumber: c.prNumber,
            path: c.path, line: c.line, body: c.body,
            author: c.author, createdAt: c.createdAt
        )
    }
}

private struct ReviewCommentListDTO: Content {
    let user: String
    let repo: String
    let prNumber: Int
    let reviewID: Int
    let count: Int
    let comments: [ReviewCommentDTO]
}
