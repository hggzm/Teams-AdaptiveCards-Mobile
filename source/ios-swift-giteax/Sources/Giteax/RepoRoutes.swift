import Foundation
import Vapor

/// Registers the Phase 3 + Phase 4 + Phase 5 + Phase 6 + Phase 7 routes:
///
///   GET /:user/:repo                  -> repo summary
///   GET /:user/:repo/commits/:ref     -> paginated commit log (?limit=N, default 20, max 200)
///   GET /:user/:repo/tree/:ref        -> root tree listing
///   GET /:user/:repo/tree/:ref/<path> -> directory listing at <path>
///   GET /:user/:repo/blob/:ref/<path> -> blob bytes at <path>
///   GET /:user/:repo/diff/:base/:head -> ref-to-ref diff (per-file deltas + hunks)
///
/// Phase 7 (smart-HTTP, only registered when `smart` is non-nil):
///   GET  /:user/:repo.git/info/refs                   -> ref-advertisement
///   POST /:user/:repo.git/git-upload-pack             -> `git fetch` / `git clone`
///   POST /:user/:repo.git/git-receive-pack            -> `git push` (only if GITEAX_ALLOW_PUSH=1)
///
/// Browse routes accept `Accept: application/json` for a machine-readable
/// JSON body, falling back to a compact plaintext rendering. Blob
/// responses are an exception: the JSON form returns metadata-only
/// (size, oid, isBinary, kind), and the non-JSON form streams the raw
/// bytes with a content-type guess. Diff responses use a `git diff`-style
/// unified plaintext when JSON is not requested.
func registerRepoRoutes(_ app: Application,
                        service: RepositoryService,
                        smart: SmartHTTPService? = nil,
                        pushAuth: GitPushBasicAuth? = nil,
                        events: EventSink = DiscardEventSink(),
                        access: AccessController? = nil,
                        hookInstaller: HookInstaller? = nil,
                        metaStore: RepoMetaStore? = nil) {
    // Make sure the threadPool is alive; Application.make creates it by default.
    let pool = app.threadPool

    /// Run a blocking libgit2 closure off the event loop, with proper
    /// async/await ergonomics.
    @Sendable
    func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await pool.runIfActive(work)
    }

    /// Phase 12 read gate. Anon OK on public repos; authed-only on
    /// internal; collaborators on private. Throws Abort with proper
    /// 401/403/404 mapping (and WWW-Authenticate on 401).
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

    /// Phase 12 write gate for git-receive-pack. We've already passed
    /// the Phase-8 HTTP-Basic check at this point (pushAuth.gate stashed
    /// the username on req.storage); now check per-repo write perm.
    /// Phase 13/28: if the repo has ANY protected branches set AND the\n    /// hook installer is NOT wired, the push is gated at admin level\n    /// (we can't parse pack contents from Vapor's perspective).\n    /// When the hook installer IS wired (Phase 27/28+), this gate\n    /// relaxes to plain `.write` -- the per-branch ACL is enforced\n    /// precisely in the auto-installed pre-receive hook, which sees\n    /// the actual refs being pushed.
    @Sendable
    func gateWrite(_ req: Request, user: String, repo: String) async throws {
        guard let access else { return }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            // Should never happen if pushAuth.gate ran first; defend.
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        do {
            if hookInstaller != nil {
                // Pre-receive hook will reject per-branch -- just require write.
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write,
                    user: user, repo: repo,
                    scope: "pushing to this repository"
                )
            } else {
                try await access.requireBranchWrite(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    user: user, repo: repo, branch: nil,
                    scope: "pushing to this repository"
                )
            }
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
    }

    app.get(":user", ":repo") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        try await gateRead(req, user: user, repo: repo)
        let summary: RepositoryService.Summary
        do {
            summary = try await runBlocking { try service.summary(user: user, repo: repo) }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        return try renderSummary(summary, on: req)
    }

    app.get(":user", ":repo", "commits", ":ref") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let ref  = req.parameters.get("ref")
        else {
            throw Abort(.badRequest, reason: "missing :user, :repo or :ref")
        }
        try await gateRead(req, user: user, repo: repo)
        let limit = clamp(Int(req.query[String.self, at: "limit"] ?? "") ?? 20, min: 1, max: 200)
        let commits: [RepositoryService.CommitInfo]
        do {
            commits = try await runBlocking { try service.log(user: user, repo: repo, ref: ref, limit: limit) }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        return try renderCommits(commits, on: req, user: user, repo: repo, ref: ref)
    }

    // Phase 54: contributors. Walks commits reachable from `?ref=` (default HEAD),
    // groups by (author name + email) case-insensitively, returns rows sorted by
    // descending commit count. Bounded BFS via the SwiftGitX log iterator.
    // Query: ?ref=<refspec>&limit=<1..1000, default 100>&max_commits=<1..50000, default 10000>
    app.get("api", "repos", ":user", ":repo", "contributors") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        try await gateRead(req, user: user, repo: repo)
        let ref = req.query[String.self, at: "ref"] ?? "HEAD"
        let limit = clamp(Int(req.query[String.self, at: "limit"] ?? "") ?? 100, min: 1, max: 1000)
        let maxCommits = clamp(Int(req.query[String.self, at: "max_commits"] ?? "") ?? 10_000, min: 1, max: 50_000)
        let rows: [RepositoryService.ContributorRow]
        do {
            rows = try await runBlocking {
                try service.contributors(user: user, repo: repo, ref: ref, maxCommits: maxCommits, limit: limit)
            }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        struct DTO: Content {
            let user: String
            let repo: String
            let ref: String
            let count: Int
            let contributors: [RepositoryService.ContributorRow]
        }
        let resp = Response(status: .ok)
        try resp.content.encode(DTO(user: user, repo: repo, ref: ref, count: rows.count, contributors: rows), as: .json)
        return resp
    }

    // Phase 55: branches API. Lists git branches with HEAD commit metadata.
    // Default branch (per RepoMetaStore settings) is hoisted first when known.
    app.get("api", "repos", ":user", ":repo", "branches") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        try await gateRead(req, user: user, repo: repo)
        let def: String? = await {
            guard let m = metaStore else { return nil }
            return (try? await m.get(user: user, repo: repo))?.defaultBranch
        }()
        let rows: [RepositoryService.BranchRow]
        do {
            rows = try await runBlocking {
                try service.branches(user: user, repo: repo, defaultBranch: def)
            }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        struct DTO: Content {
            let user: String
            let repo: String
            let count: Int
            let defaultBranch: String?
            let branches: [RepositoryService.BranchRow]
        }
        let resp = Response(status: .ok)
        try resp.content.encode(DTO(user: user, repo: repo, count: rows.count, defaultBranch: def, branches: rows), as: .json)
        return resp
    }

    app.get("api", "repos", ":user", ":repo", "branches", ":name") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let name = req.parameters.get("name")
        else { throw Abort(.badRequest, reason: "missing :user, :repo or :name") }
        try await gateRead(req, user: user, repo: repo)
        let def: String? = await {
            guard let m = metaStore else { return nil }
            return (try? await m.get(user: user, repo: repo))?.defaultBranch
        }()
        let row: RepositoryService.BranchRow?
        do {
            row = try await runBlocking {
                try service.branch(user: user, repo: repo, name: name, defaultBranch: def)
            }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        guard let row = row else {
            throw Abort(.notFound, reason: "branch '\(name)' not found")
        }
        let resp = Response(status: .ok)
        try resp.content.encode(row, as: .json)
        return resp
    }

    // Phase 4: tree listing.
    let treeHandler: @Sendable (Request) async throws -> Response = { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let ref  = req.parameters.get("ref")
        else {
            throw Abort(.badRequest, reason: "missing :user, :repo or :ref")
        }
        try await gateRead(req, user: user, repo: repo)
        let path = req.parameters.getCatchall().joined(separator: "/")
        let listing: RepositoryService.TreeListing
        do {
            listing = try await runBlocking {
                try service.tree(user: user, repo: repo, ref: ref, path: path)
            }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        return try renderTree(listing, on: req)
    }
    app.get(":user", ":repo", "tree", ":ref", use: treeHandler)
    app.get(":user", ":repo", "tree", ":ref", "**", use: treeHandler)

    // Phase 4: blob bytes. Catchall path must be non-empty for blobs --
    // a tree-level "/blob/:ref" with no path is a 400.
    app.get(":user", ":repo", "blob", ":ref", "**") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let ref  = req.parameters.get("ref")
        else {
            throw Abort(.badRequest, reason: "missing :user, :repo or :ref")
        }
        try await gateRead(req, user: user, repo: repo)
        let path = req.parameters.getCatchall().joined(separator: "/")
        guard !path.isEmpty else {
            throw Abort(.badRequest, reason: "blob path is required")
        }
        let (info, data): (RepositoryService.BlobInfo, Data)
        do {
            (info, data) = try await runBlocking {
                try service.blob(user: user, repo: repo, ref: ref, path: path)
            }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        return try renderBlob(info: info, data: data, on: req)
    }

    // Phase 5: ref-to-ref diff. Two refs in separate path segments instead of
    // `:base..:head` because the dot would clash with our name-segment grammar.
    app.get(":user", ":repo", "diff", ":base", ":head") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo"),
              let base = req.parameters.get("base"),
              let head = req.parameters.get("head")
        else {
            throw Abort(.badRequest, reason: "missing :user, :repo, :base, or :head")
        }
        try await gateRead(req, user: user, repo: repo)
        let result: RepositoryService.DiffResult
        do {
            result = try await runBlocking {
                try service.diff(user: user, repo: repo, base: base, head: head)
            }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        return try renderDiff(result, on: req)
    }

    // Phase 7: smart-HTTP via `git http-backend`. Only registered when
    // SmartHTTPService construction succeeded at startup (i.e. the CGI
    // helper was reachable). When `smart == nil`, the routes below are
    // simply not bound -- a `git clone http://...` against the server
    // gets a 404 instead of a confusing 500.
    guard let smart else { return }

    /// Resolves the (user, repo) tuple from the route parameters and
    /// runs the CGI subprocess off the event loop. Returns a Vapor
    /// Response with the CGI status/headers/body verbatim.
    @Sendable
    func runSmart(
        _ req: Request,
        suffix: String  // "info/refs" / "git-upload-pack" / "git-receive-pack"
    ) async throws -> Response {
        guard let user = req.parameters.get("user"),
              let repoDotGit = req.parameters.get("repo")
        else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        let repo: String
        do {
            repo = try SmartHTTPService.stripGitSuffix(repoDotGit)
        } catch let e as SmartHTTPService.BackendError {
            throw Abort(e.status, reason: e.reason)
        }
        // Buffer the full body. Vapor's default body-collection ceiling is
        // 16 KB, which is fine for `info/refs` but too small for any real
        // push body. We bump to 64 MB which comfortably covers a typical
        // single-commit push without sweating big monorepos. Real
        // streaming is a future optimisation.
        let body: Data
        if let buffer = req.body.data {
            body = Data(buffer: buffer)
        } else {
            let collected = try await req.body.collect(max: 64 * 1024 * 1024).get()
            if let buffer = collected {
                body = Data(buffer: buffer)
            } else {
                body = Data()
            }
        }
        let qs: String = req.url.query ?? ""
        let ct: String? = req.headers.first(name: .contentType)
        let method: String = req.method.rawValue
        let pushedByUser = req.storage[GitPushAuthedUserKey.self]
        let cgi: SmartHTTPService.Response
        do {
            cgi = try await app.threadPool.runIfActive { [smart] in
                try smart.dispatch(
                    method: method,
                    user: user,
                    repo: repo,
                    pathInfoSuffix: suffix,
                    queryString: qs,
                    contentType: ct,
                    body: body,
                    pushedBy: pushedByUser
                )
            }
        } catch let e as SmartHTTPService.BackendError {
            throw Abort(e.status, reason: e.reason)
        }

        let r = Response(status: cgi.status)
        for h in cgi.headers {
            r.headers.add(name: h.name, value: h.value)
        }
        r.body = .init(data: cgi.body)
        return r
    }

    app.get(":user", ":repo", "info", "refs") { req async throws -> Response in
        // Phase 8: gate receive-pack discovery behind HTTP Basic auth.
        // Upload-pack discovery (clone/fetch) is anonymous.
        if let pushAuth,
           req.url.query?.contains("service=git-receive-pack") == true {
            if let response = try await pushAuth.gate(req) {
                return response
            }
        }
        // Phase 12: per-repo permission check.
        // Upload-pack discovery needs READ; receive-pack discovery needs WRITE.
        if let user = req.parameters.get("user"),
           let repoDotGit = req.parameters.get("repo"),
           let repo = try? SmartHTTPService.stripGitSuffix(repoDotGit) {
            if req.url.query?.contains("service=git-receive-pack") == true {
                try await gateWrite(req, user: user, repo: repo)
                // Phase 27/28: install hooks at discovery time too so a
                // client that does the GET info/refs handshake but never
                // POSTs git-receive-pack (e.g. an interactive smoke
                // probe) still ends up with hooks on disk.
                if let hookInstaller {
                    await hookInstaller.ensureInstalled(user: user, repo: repo)
                }
            } else {
                try await gateRead(req, user: user, repo: repo)
            }
        }
        return try await runSmart(req, suffix: "info/refs")
    }
    app.post(":user", ":repo", "git-upload-pack") { req async throws -> Response in
        // Phase 12: clone needs READ on the repo. For public repos this
        // is a no-op when no Authorization header is sent; for private
        // repos it requires Basic auth.
        if let access,
           let user = req.parameters.get("user"),
           let repoDotGit = req.parameters.get("repo"),
           let repo = try? SmartHTTPService.stripGitSuffix(repoDotGit) {
            _ = access  // suppress unused when no auth header
            try await gateRead(req, user: user, repo: repo)
        }
        return try await runSmart(req, suffix: "git-upload-pack")
    }
    // Phase 8: receive-pack is fully behind HTTP Basic auth when a
    // pushAuth middleware is configured. When `pushAuth == nil`, the
    // SmartHTTPService's allowPush=false gate trips inside `runSmart`
    // and returns the Phase-7 403.
    let receivePackPost: @Sendable (Request) async throws -> Response = { req in
        if let pushAuth {
            if let response = try await pushAuth.gate(req) {
                return response
            }
        }
        // Phase 12: per-repo write permission on top of pushAuth.
        if let user = req.parameters.get("user"),
           let repoDotGit = req.parameters.get("repo"),
           let repo = try? SmartHTTPService.stripGitSuffix(repoDotGit) {
            try await gateWrite(req, user: user, repo: repo)
        }
        // Phase 27/28: install hooks before forwarding to CGI so an
        // accepting push has both pre-receive (per-branch ACL) and
        // post-receive (OOB-safety-net event) in place.
        if let hookInstaller,
           let user = req.parameters.get("user"),
           let repoDotGit = req.parameters.get("repo"),
           let repo = try? SmartHTTPService.stripGitSuffix(repoDotGit) {
            await hookInstaller.ensureInstalled(user: user, repo: repo)
        }
        // Phase 20: pre-push ref snapshot. Used to compute a diff for
        // the push payload below. Failures here are non-fatal -- we just
        // emit a less-rich payload.
        var beforeRefs: [String: String] = [:]
        if let user = req.parameters.get("user"),
           let repoDotGit = req.parameters.get("repo"),
           let repo = try? SmartHTTPService.stripGitSuffix(repoDotGit) {
            beforeRefs = (try? await runBlocking { try service.refSnapshot(user: user, repo: repo) }) ?? [:]
        }
        let response = try await runSmart(req, suffix: "git-receive-pack")
        // Fire a `push` event on successful CGI exit. Phase 20: compute
        // the before/after ref diff so receivers see exactly which refs
        // moved without a re-fetch.
        if (200..<300).contains(response.status.code),
           let user = req.parameters.get("user"),
           let repoDotGit = req.parameters.get("repo"),
           let repo = try? SmartHTTPService.stripGitSuffix(repoDotGit) {
            let pusher = req.storage[GitPushAuthedUserKey.self] ?? "(anonymous)"
            let afterRefs = (try? await runBlocking { try service.refSnapshot(user: user, repo: repo) }) ?? [:]
            var refUpdates: [[String: Any]] = []
            // Created + updated refs.
            for (name, after) in afterRefs.sorted(by: { $0.key < $1.key }) {
                let before = beforeRefs[name] ?? "0000000000000000000000000000000000000000"
                if before != after {
                    refUpdates.append([
                        "ref": "refs/heads/\(name)",
                        "before": before,
                        "after": after,
                        "kind": (beforeRefs[name] == nil) ? "created" : "updated",
                    ])
                }
            }
            // Deleted refs.
            for (name, before) in beforeRefs.sorted(by: { $0.key < $1.key }) {
                if afterRefs[name] == nil {
                    refUpdates.append([
                        "ref": "refs/heads/\(name)",
                        "before": before,
                        "after": "0000000000000000000000000000000000000000",
                        "kind": "deleted",
                    ])
                }
            }
            await events.fire(user: user, repo: repo, event: "push", payload: [
                "pusher": pusher,
                "refUpdateCount": refUpdates.count,
                "refUpdates": refUpdates,
            ])
        }
        return response
    }
    app.post(":user", ":repo", "git-receive-pack", use: receivePackPost)
}

// MARK: - Rendering

private func renderSummary(_ s: RepositoryService.Summary, on req: Request) throws -> Response {
    if wantsJSON(req) {
        let body = SummaryDTO(
            user: s.user,
            repo: s.repo,
            isBare: s.isBare,
            isEmpty: s.isEmpty,
            isHEADDetached: s.isHEADDetached,
            isHEADUnborn: s.isHEADUnborn,
            headBranch: s.headBranch,
            headCommit: s.headCommit,
            branchCount: s.branchCount,
            branches: s.branches
        )
        return try jsonResponse(body)
    }
    var out = ""
    out += "repository: \(s.user)/\(s.repo)\n"
    out += "bare: \(s.isBare)\n"
    out += "empty: \(s.isEmpty)\n"
    out += "head:\n"
    if s.isHEADUnborn {
        out += "  unborn (no commits yet)\n"
    } else if s.isHEADDetached {
        out += "  detached HEAD\n"
    } else if let b = s.headBranch {
        out += "  branch: \(b)\n"
    }
    if let c = s.headCommit {
        out += "  commit: \(c.id)\n"
        out += "  summary: \(c.summary)\n"
        out += "  author: \(c.authorName) <\(c.authorEmail)>\n"
        out += "  date: \(c.date)\n"
    }
    out += "branches (\(s.branchCount)):\n"
    for b in s.branches { out += "  - \(b)\n" }
    return plaintextResponse(out)
}

private func renderCommits(
    _ commits: [RepositoryService.CommitInfo],
    on req: Request,
    user: String,
    repo: String,
    ref: String
) throws -> Response {
    if wantsJSON(req) {
        return try jsonResponse(CommitsDTO(
            user: user, repo: repo, ref: ref, count: commits.count, commits: commits
        ))
    }
    var out = "commits in \(user)/\(repo)@\(ref) (\(commits.count)):\n"
    for c in commits {
        out += "  \(c.id.prefix(8))  \(c.authorName)  \(c.summary)\n"
    }
    return plaintextResponse(out)
}

private func renderTree(
    _ listing: RepositoryService.TreeListing,
    on req: Request
) throws -> Response {
    if wantsJSON(req) {
        return try jsonResponse(TreeDTO(
            user: listing.user, repo: listing.repo, ref: listing.ref,
            path: listing.path, count: listing.entries.count,
            entries: listing.entries
        ))
    }
    var out = "tree \(listing.user)/\(listing.repo)@\(listing.ref):\(listing.path) (\(listing.entries.count) entries):\n"
    for e in listing.entries {
        let marker: String
        switch e.kind {
        case "tree":           marker = "d "
        case "blobExecutable": marker = "x "
        case "symlink":        marker = "l "
        case "commit":         marker = "s "  // submodule
        default:               marker = "  "
        }
        let sizeStr = e.size.map { String(format: "%9d", $0) } ?? "         "
        out += "\(marker)\(e.oid.prefix(8))  \(sizeStr)  \(e.name)\n"
    }
    return plaintextResponse(out)
}

private func renderBlob(
    info: RepositoryService.BlobInfo,
    data: Data,
    on req: Request
) throws -> Response {
    // JSON form is metadata-only; raw bytes only flow over non-JSON GET.
    if wantsJSON(req) {
        return try jsonResponse(BlobMetadataDTO(
            user: info.user, repo: info.repo, ref: info.ref,
            path: info.path, oid: info.oid, size: info.size,
            isBinary: info.isBinary, kind: info.kind
        ))
    }
    let r = Response(status: .ok)
    let ct = contentTypeForBlob(path: info.path, isBinary: info.isBinary)
    r.headers.replaceOrAdd(name: .contentType, value: ct)
    // Strong validator: object IDs are content-addressed.
    r.headers.replaceOrAdd(name: .eTag, value: "\"\(info.oid)\"")
    r.headers.replaceOrAdd(name: "X-Giteax-Object-Id", value: info.oid)
    r.headers.replaceOrAdd(name: "X-Giteax-Blob-Kind", value: info.kind)
    r.body = .init(data: data)
    return r
}

private func renderDiff(_ d: RepositoryService.DiffResult, on req: Request) throws -> Response {
    if wantsJSON(req) {
        // DiffResult is already Codable; serve directly.
        let r = Response(status: .ok)
        try r.content.encode(d, as: .json)
        return r
    }
    // git-diff(1)-style unified text. Stable enough for human consumption
    // and for piping through `colordiff` / `delta` clients.
    var out = ""
    out += "diff \(d.user)/\(d.repo) \(d.base)..\(d.head)\n"
    out += "base commit: \(d.baseCommit)\n"
    out += "head commit: \(d.headCommit)\n"
    out += "files: \(d.fileCount)\n"
    out += "\n"
    for f in d.files {
        let oldP = f.oldPath ?? "/dev/null"
        let newP = f.newPath ?? "/dev/null"
        out += "diff --giteax a/\(oldP) b/\(newP)\n"
        out += "status: \(f.status)"
        if let sim = f.similarity { out += " (similarity \(sim))" }
        out += "\n"
        if let oOID = f.oldOid { out += "old oid: \(oOID)\n" }
        if let nOID = f.newOid { out += "new oid: \(nOID)\n" }
        out += "--- a/\(oldP)\n"
        out += "+++ b/\(newP)\n"
        if f.isBinary {
            out += "Binary files differ.\n\n"
            continue
        }
        guard let hunks = f.hunks else {
            out += "(no textual patch available)\n\n"
            continue
        }
        for h in hunks {
            out += h.header
            if !h.header.hasSuffix("\n") { out += "\n" }
            for line in h.lines {
                let prefix: String
                switch line.kind {
                case "addition", "additionEOF":   prefix = "+"
                case "deletion", "deletionEOF":   prefix = "-"
                default:                          prefix = " "
                }
                // libgit2 already terminates each line's content with \n;
                // don't add a second one.
                out += prefix + line.content
                if !line.content.hasSuffix("\n") { out += "\n" }
            }
        }
        out += "\n"
    }
    return plaintextResponse(out)
}

// MARK: - Codable DTOs

private struct SummaryDTO: Content {
    let user: String
    let repo: String
    let isBare: Bool
    let isEmpty: Bool
    let isHEADDetached: Bool
    let isHEADUnborn: Bool
    let headBranch: String?
    let headCommit: RepositoryService.CommitInfo?
    let branchCount: Int
    let branches: [String]
}

private struct CommitsDTO: Content {
    let user: String
    let repo: String
    let ref: String
    let count: Int
    let commits: [RepositoryService.CommitInfo]
}

private struct TreeDTO: Content {
    let user: String
    let repo: String
    let ref: String
    let path: String
    let count: Int
    let entries: [RepositoryService.TreeEntry]
}

private struct BlobMetadataDTO: Content {
    let user: String
    let repo: String
    let ref: String
    let path: String
    let oid: String
    let size: Int
    let isBinary: Bool
    let kind: String
}

// MARK: - Helpers

private func wantsJSON(_ req: Request) -> Bool {
    if let accept = req.headers.first(name: .accept),
       accept.lowercased().contains("application/json") {
        return true
    }
    return req.query[String.self, at: "format"]?.lowercased() == "json"
}

private func plaintextResponse(_ body: String) -> Response {
    let r = Response(status: .ok)
    r.headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
    r.body = .init(string: body)
    return r
}

private func jsonResponse<E: Encodable>(_ value: E) throws -> Response {
    let r = Response(status: .ok)
    try r.content.encode(value, as: .json)
    return r
}

private func clamp(_ x: Int, min lo: Int, max hi: Int) -> Int {
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}

/// Tiny extension-to-MIME mapping for the blob endpoint. We intentionally
/// keep this small -- the goal is a useful default for source browsing,
/// not full MIME-type negotiation. Unknown extensions fall back to
/// "text/plain; charset=utf-8" for text and "application/octet-stream"
/// for binary blobs.
private let blobContentTypeByExtension: [String: String] = [
    "swift":      "text/x-swift; charset=utf-8",
    "c":          "text/x-c; charset=utf-8",
    "h":          "text/x-c; charset=utf-8",
    "cc":         "text/x-c++; charset=utf-8",
    "cpp":        "text/x-c++; charset=utf-8",
    "hpp":        "text/x-c++; charset=utf-8",
    "m":          "text/x-objc; charset=utf-8",
    "mm":         "text/x-objc++; charset=utf-8",
    "rs":         "text/x-rust; charset=utf-8",
    "go":         "text/x-go; charset=utf-8",
    "py":         "text/x-python; charset=utf-8",
    "rb":         "text/x-ruby; charset=utf-8",
    "js":         "application/javascript; charset=utf-8",
    "ts":         "application/typescript; charset=utf-8",
    "jsx":        "text/jsx; charset=utf-8",
    "tsx":        "text/tsx; charset=utf-8",
    "json":       "application/json; charset=utf-8",
    "yaml":       "application/yaml; charset=utf-8",
    "yml":        "application/yaml; charset=utf-8",
    "toml":       "application/toml; charset=utf-8",
    "md":         "text/markdown; charset=utf-8",
    "txt":        "text/plain; charset=utf-8",
    "html":       "text/html; charset=utf-8",
    "css":        "text/css; charset=utf-8",
    "xml":        "application/xml; charset=utf-8",
    "sh":         "application/x-sh; charset=utf-8",
    "ps1":        "application/x-powershell; charset=utf-8",
    "png":        "image/png",
    "jpg":        "image/jpeg",
    "jpeg":       "image/jpeg",
    "gif":        "image/gif",
    "svg":        "image/svg+xml",
    "webp":       "image/webp",
    "pdf":        "application/pdf",
    "zip":        "application/zip",
    "tar":        "application/x-tar",
    "gz":         "application/gzip",
]

private func contentTypeForBlob(path: String, isBinary: Bool) -> String {
    let lower = path.lowercased()
    if let dot = lower.lastIndex(of: ".") {
        let ext = String(lower[lower.index(after: dot)...])
        if let ct = blobContentTypeByExtension[ext] {
            return ct
        }
    }
    return isBinary ? "application/octet-stream" : "text/plain; charset=utf-8"
}
