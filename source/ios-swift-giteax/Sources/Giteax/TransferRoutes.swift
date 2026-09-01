import Foundation
import Vapor

/// Phase 44 -- repo transfer + rename.
///
///   POST   /api/repos/:user/:repo/transfer   (auth, admin)
///       body: { "newOwner": "alice" }
///       Moves the bare repo dir AND the per-repo state dir under
///       `<root>/.giteax/repos/<u>/<r>/` to a new owner. `newOwner`
///       must be the requester themselves OR an org they own.
///
///   POST   /api/repos/:user/:repo/rename     (auth, admin)
///       body: { "newName": "diffy" }
///       Same as transfer but only the repo segment changes; owner is
///       preserved.
///
/// Side-effects in both cases:
///   1. Physical move of `<root>/<oldOwner>/<oldRepo>.git` to the new path.
///   2. Physical move of `<root>/.giteax/repos/<oldOwner>/<oldRepo>` to the
///      new path (carries issues, prs, labels, milestones, webhooks, wiki,
///      meta, releases, reviews, LFS objects, packages, code-index, and
///      activity log).
///   3. Rewrite `forks.json` rows whose child or parent referenced the old
///      pair so they now reference the new pair.
///   4. Rewrite `stars.json` and `watches.json` rows targeting the old pair.
///
/// NOT carried over by this version:
///   - Cross-fork PRs in *other* repos that hold `headOwner`/`headRepo`
///     pointing at the old pair are not rewritten. (No global PR index
///     exists; walking every repo would be unbounded. Operators doing a
///     transfer should expect cross-fork PR open against the OLD path to
///     start returning 404 from the head-fetch step.)
///   - The renamed/transferred repo keeps its hook scripts pointed at the
///     same loopback URL; the per-repo hook token is still valid because
///     it's part of `meta.json` which moves with the state dir.
///
/// Errors:
///   - 400 invalid new segment, transferring to self, missing body
///   - 401/403 auth missing or not admin on source
///   - 404 source repo missing
///   - 409 destination already exists
///   - 500 IO failure
func registerTransferRoutes(
    _ app: Application,
    forks: ForkStore,
    stars: StarStore,
    watches: WatchStore,
    meta: RepoMetaStore,
    issues: IssueStore,
    labels: LabelStore,
    milestones: MilestoneStore,
    prs: PullRequestStore,
    webhooks: WebhookStore,
    releases: ReleaseStore,
    reviews: PRReviewStore,
    codeIndex: CodeIndex,
    orgs: OrgStore?,
    pushAuth: GitPushBasicAuth?,
    access: AccessController,
    rootURL: URL
) {

    @Sendable
    func requireAuthor(_ req: Request) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "repo transfer/rename disabled (set GITEAX_ALLOW_PUSH=1 and create a user)")
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
    func requireAdmin(_ req: Request, user: String, repo: String) async throws {
        let identity = await access.identify(req)
        do {
            try await access.require(
                identity, atLeast: .admin,
                user: user, repo: repo,
                scope: "transferring or renaming this repository"
            )
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
    }

    @Sendable
    func authorizeTargetOwner(author: String, targetOwner: String) async throws {
        if targetOwner == author { return }
        if let orgs, let org = try await orgs.get(targetOwner) {
            guard org.owners.contains(author) else {
                throw Abort(.forbidden, reason: "must be an owner of organization '\(targetOwner)' to transfer into it")
            }
            return
        }
        throw Abort(.forbidden, reason: "target owner '\(targetOwner)' is neither you nor an org you own")
    }

    @Sendable
    func performMove(
        oldOwner: String, oldRepo: String,
        newOwner: String, newRepo: String
    ) async throws {
        let fm = FileManager.default

        let srcBare  = rootURL.appendingPathComponent(oldOwner)
            .appendingPathComponent("\(oldRepo).git")
        let dstOwnerDir = rootURL.appendingPathComponent(newOwner)
        let dstBare  = dstOwnerDir.appendingPathComponent("\(newRepo).git")

        let srcState = rootURL.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(oldOwner, isDirectory: true)
            .appendingPathComponent(oldRepo,  isDirectory: true)
        let dstStateParent = rootURL.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(newOwner, isDirectory: true)
        let dstState = dstStateParent.appendingPathComponent(newRepo, isDirectory: true)

        guard fm.fileExists(atPath: srcBare.path) else {
            throw Abort(.notFound, reason: "source bare repo not found: \(oldOwner)/\(oldRepo).git")
        }
        if fm.fileExists(atPath: dstBare.path) {
            throw Abort(.conflict, reason: "destination bare repo already exists: \(newOwner)/\(newRepo).git")
        }
        if fm.fileExists(atPath: dstState.path) {
            throw Abort(.conflict, reason: "destination state dir already exists: .giteax/repos/\(newOwner)/\(newRepo)")
        }

        // Evict all per-repo caches for the OLD path BEFORE moving:
        //   - prevents stale reads on the old path after the move
        //   - closes the SQLite handle in CodeIndex (Windows would block
        //     the directory move if any file inside has an open handle)
        // Also evict any cached negative-lookup at the NEW path.
        await meta.evictRepo(user: oldOwner,   repo: oldRepo)
        await meta.evictRepo(user: newOwner,   repo: newRepo)
        await issues.evictRepo(user: oldOwner, repo: oldRepo)
        await issues.evictRepo(user: newOwner, repo: newRepo)
        await labels.evictRepo(user: oldOwner, repo: oldRepo)
        await labels.evictRepo(user: newOwner, repo: newRepo)
        await milestones.evictRepo(user: oldOwner, repo: oldRepo)
        await milestones.evictRepo(user: newOwner, repo: newRepo)
        await prs.evictRepo(user: oldOwner,    repo: oldRepo)
        await prs.evictRepo(user: newOwner,    repo: newRepo)
        await webhooks.evictRepo(user: oldOwner, repo: oldRepo)
        await webhooks.evictRepo(user: newOwner, repo: newRepo)
        await releases.evictRepo(user: oldOwner, repo: oldRepo)
        await releases.evictRepo(user: newOwner, repo: newRepo)
        await reviews.evictRepo(user: oldOwner, repo: oldRepo)
        await reviews.evictRepo(user: newOwner, repo: newRepo)
        await codeIndex.evictRepo(user: oldOwner, repo: oldRepo)
        await codeIndex.evictRepo(user: newOwner, repo: newRepo)

        do {
            try fm.createDirectory(at: dstOwnerDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dstStateParent, withIntermediateDirectories: true)
        } catch {
            throw Abort(.internalServerError, reason: "could not create destination dirs: \(error)")
        }

        // Move bare repo.
        do {
            try fm.moveItem(at: srcBare, to: dstBare)
        } catch {
            throw Abort(.internalServerError, reason: "moveItem(bare) failed: \(error)")
        }

        // Move state dir (may not exist for a freshly cloned repo with
        // no issues / PRs / etc -- that's fine).
        if fm.fileExists(atPath: srcState.path) {
            do {
                try fm.moveItem(at: srcState, to: dstState)
            } catch {
                // Roll back the bare move so retries are clean.
                try? fm.moveItem(at: dstBare, to: srcBare)
                throw Abort(.internalServerError, reason: "moveItem(state) failed: \(error)")
            }
        }

        // Rewrite global stores.
        _ = try await forks.rewriteRepoRef(
            from: .init(owner: oldOwner, repo: oldRepo),
            to:   .init(owner: newOwner, repo: newRepo)
        )
        _ = try await stars.rewriteRepoRef(
            oldOwner: oldOwner, oldRepo: oldRepo,
            newOwner: newOwner, newRepo: newRepo
        )
        _ = try await watches.rewriteRepoRef(
            oldOwner: oldOwner, oldRepo: oldRepo,
            newOwner: newOwner, newRepo: newRepo
        )
    }

    // MARK: - Transfer

    app.post("api", "repos", ":user", ":repo", "transfer") { req async throws -> Response in
        guard let oldOwner = req.parameters.get("user"),
              let oldRepo  = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }

        let author = try await requireAuthor(req)
        try await requireAdmin(req, user: oldOwner, repo: oldRepo)

        let body = try req.content.decode(TransferDTO.self)
        let newOwner = body.newOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newOwner.isEmpty else { throw Abort(.badRequest, reason: "newOwner is required") }
        guard RepositoryService.validateSegment(newOwner)
        else { throw Abort(.badRequest, reason: "newOwner must match [A-Za-z0-9][A-Za-z0-9._-]*") }
        guard newOwner != oldOwner
        else { throw Abort(.badRequest, reason: "newOwner is the same as current owner") }

        try await authorizeTargetOwner(author: author, targetOwner: newOwner)

        try await performMove(
            oldOwner: oldOwner, oldRepo: oldRepo,
            newOwner: newOwner, newRepo: oldRepo
        )

        let resp = Response(status: .ok)
        try resp.content.encode(MovedDTO(
            oldOwner: oldOwner, oldRepo: oldRepo,
            newOwner: newOwner, newRepo: oldRepo
        ), as: .json)
        return resp
    }

    // MARK: - Rename

    app.post("api", "repos", ":user", ":repo", "rename") { req async throws -> Response in
        guard let oldOwner = req.parameters.get("user"),
              let oldRepo  = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user/:repo") }

        _ = try await requireAuthor(req)
        try await requireAdmin(req, user: oldOwner, repo: oldRepo)

        let body = try req.content.decode(RenameDTO.self)
        let newRepo = body.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newRepo.isEmpty else { throw Abort(.badRequest, reason: "newName is required") }
        guard RepositoryService.validateSegment(newRepo)
        else { throw Abort(.badRequest, reason: "newName must match [A-Za-z0-9][A-Za-z0-9._-]*") }
        guard newRepo != oldRepo
        else { throw Abort(.badRequest, reason: "newName is the same as current name") }

        try await performMove(
            oldOwner: oldOwner, oldRepo: oldRepo,
            newOwner: oldOwner, newRepo: newRepo
        )

        let resp = Response(status: .ok)
        try resp.content.encode(MovedDTO(
            oldOwner: oldOwner, oldRepo: oldRepo,
            newOwner: oldOwner, newRepo: newRepo
        ), as: .json)
        return resp
    }
}

// MARK: - DTOs

private struct TransferDTO: Content {
    let newOwner: String
}

private struct RenameDTO: Content {
    let newName: String
}

private struct MovedDTO: Content {
    let oldOwner: String
    let oldRepo: String
    let newOwner: String
    let newRepo: String
}
