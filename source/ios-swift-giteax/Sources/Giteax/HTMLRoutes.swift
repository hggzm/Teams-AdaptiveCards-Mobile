// hggz/giteax -- Phase 14: minimal HTML UI under /ui/*.
//
// Sits ON TOP of the existing JSON API. Every route here is a thin
// read-only renderer that calls the same stores/services the JSON API
// uses, then emits a single-file HTML page with inline CSS so we don't
// drag in Leaf or any other templating dep. The /api/* surface, the
// existing /:user/:repo plaintext browse, and smart-HTTP all remain
// unchanged.
//
// Routes:
//   GET /ui                                    -- landing (repo list)
//   GET /ui/:user                              -- repos under one namespace
//   GET /ui/:user/:repo                        -- repo overview (refs, head commit)
//   GET /ui/:user/:repo/commits                -- commit log on default branch
//   GET /ui/:user/:repo/issues                 -- issue list
//   GET /ui/:user/:repo/pulls                  -- PR list
//   GET /ui/:user/:repo/releases               -- release list
//
// Access gating: each route invokes the same AccessController used by
// the JSON API. Anon-on-private returns 401 + WWW-Authenticate so the
// browser prompts; authed-non-collab returns 404 to avoid leaking
// existence. Public repos remain anon-readable.

import Vapor
import Foundation

func registerHTMLRoutes(
    _ app: Application,
    service: RepositoryService,
    metaStore: RepoMetaStore,
    issueStore: IssueStore,
    prStore: PullRequestStore,
    releaseStore: ReleaseStore,
    rootURL: URL,
    access: AccessController?
) {
    // MARK: - Off-event-loop blocking helper (mirrors RepoRoutes)

    let pool = app.threadPool
    @Sendable
    func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await pool.runIfActive(work)
    }

    // MARK: - Gating helpers (mirrors RepoRoutes.gateRead)

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
    func currentIdentityName(_ req: Request) async -> String? {
        guard let access else { return nil }
        return await access.identify(req).name
    }

    // MARK: - Date formatter (ISO-ish, stable)
    // Note: ISO8601DateFormatter is non-Sendable, so we instantiate per
    // call rather than capture one in @Sendable closures. Each call is
    // microseconds; bounded list pages stay well under a millisecond total.
    @Sendable
    func fmtDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: - GET /ui (landing)

    app.get("ui") { req async throws -> Response in
        // List filesystem-discovered bare repos under <root>/<user>/<repo>.git.
        // This is read-only and bounded: only top-level user dirs, only
        // *.git children. Anon ok; we still filter per-repo visibility.
        let viewer = await currentIdentityName(req)
        let pairs = discoverRepoPairs(rootURL: rootURL)
        var visible: [(user: String, repo: String, visibility: String, headBranch: String?, description: String?)] = []
        for (u, r) in pairs {
            // Cheap visibility check. Anon on private/internal -> skip.
            let allowed: Bool
            if let access {
                let id = AuthIdentity(name: viewer, isGlobalAdmin: false)
                do {
                    try await access.requireRead(id, user: u, repo: r, scope: "this repository")
                    allowed = true
                } catch {
                    allowed = false
                }
            } else {
                allowed = true
            }
            guard allowed else { continue }
            let meta = (try? await metaStore.get(user: u, repo: r))
            let visibility = meta?.visibility.rawValue ?? "public"
            let description = meta?.description
            let head: String?
            do {
                head = try await runBlocking { try service.summary(user: u, repo: r).headBranch }
            } catch { head = nil }
            visible.append((u, r, visibility, head, description))
        }
        var rows = ""
        for v in visible.sorted(by: { ($0.user, $0.repo) < ($1.user, $1.repo) }) {
            let badge = visibilityBadge(v.visibility)
            let desc = v.description.map { " — " + htmlEscape($0) } ?? ""
            let headStr = v.headBranch.map { " <span class=\"muted\">[\(htmlEscape($0))]</span>" } ?? ""
            rows += "<tr><td><a href=\"/ui/\(htmlEscape(v.user))/\(htmlEscape(v.repo))\">\(htmlEscape(v.user))/\(htmlEscape(v.repo))</a>\(headStr)\(desc)</td><td>\(badge)</td></tr>\n"
        }
        if rows.isEmpty {
            rows = "<tr><td colspan=\"2\" class=\"muted\">no repositories yet (or none visible to you)</td></tr>"
        }
        let banner = viewer.map { "signed in as <b>\(htmlEscape($0))</b>" } ?? "browsing as anon"
        let body = """
        <h1>giteax</h1>
        <p class="muted">\(banner) — <a href="/version">/version</a> · <a href="/health">/health</a></p>
        <h2>repositories</h2>
        <table class="repos">
          <thead><tr><th>name</th><th>visibility</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return htmlResponse(title: "giteax", body: body, viewer: viewer)
    }

    // MARK: - GET /ui/:user (namespace listing)

    app.get("ui", ":user") { req async throws -> Response in
        guard let user = req.parameters.get("user") else {
            throw Abort(.badRequest, reason: "missing :user")
        }
        let viewer = await currentIdentityName(req)
        let pairs = discoverRepoPairs(rootURL: rootURL).filter { $0.user == user }
        var rows = ""
        for (u, r) in pairs.sorted(by: { $0.repo < $1.repo }) {
            let allowed: Bool
            if let access {
                let id = AuthIdentity(name: viewer, isGlobalAdmin: false)
                do {
                    try await access.requireRead(id, user: u, repo: r, scope: "this repository")
                    allowed = true
                } catch { allowed = false }
            } else { allowed = true }
            guard allowed else { continue }
            let meta = (try? await metaStore.get(user: u, repo: r))
            let badge = visibilityBadge(meta?.visibility.rawValue ?? "public")
            let desc = (meta?.description).map { " \u{2014} " + htmlEscape($0) } ?? ""
            rows += "<tr><td><a href=\"/ui/\(htmlEscape(u))/\(htmlEscape(r))\">\(htmlEscape(r))</a>\(desc)</td><td>\(badge)</td></tr>\n"
        }
        if rows.isEmpty {
            rows = "<tr><td colspan=\"2\" class=\"muted\">no repositories visible under this namespace</td></tr>"
        }
        let body = """
        <p><a href="/ui">← all repositories</a></p>
        <h1>\(htmlEscape(user))</h1>
        <table class="repos">
          <thead><tr><th>repository</th><th>visibility</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return htmlResponse(title: "\(user) · giteax", body: body, viewer: viewer)
    }

    // MARK: - GET /ui/:user/:repo (overview)

    app.get("ui", ":user", ":repo") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        try await gateRead(req, user: user, repo: repo)
        let viewer = await currentIdentityName(req)
        let summary: RepositoryService.Summary
        do {
            summary = try await runBlocking { try service.summary(user: user, repo: repo) }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        let meta = (try? await metaStore.get(user: user, repo: repo))
        let visibilityStr = meta?.visibility.rawValue ?? "public"
        let description = meta?.description
        let issues = (try? await issueStore.list(user: user, repo: repo, limit: 9999))?.count ?? 0
        let prs = (try? await prStore.list(user: user, repo: repo, limit: 9999))?.count ?? 0
        let releases = (try? await releaseStore.list(user: user, repo: repo))?.count ?? 0
        let visBadge = visibilityBadge(visibilityStr)
        var headSection = ""
        if summary.isHEADUnborn {
            headSection = "<p class=\"muted\">no commits yet (unborn HEAD)</p>"
        } else if summary.isHEADDetached {
            headSection = "<p class=\"muted\">HEAD is detached</p>"
        } else if let b = summary.headBranch, let c = summary.headCommit {
            headSection = """
            <p>head branch: <code>\(htmlEscape(b))</code></p>
            <p>head commit: <code>\(htmlEscape(String(c.id.prefix(12))))</code> — \(htmlEscape(c.summary))<br>
               <span class="muted">\(htmlEscape(c.authorName)) &lt;\(htmlEscape(c.authorEmail))&gt; · \(htmlEscape(fmtDate(c.date)))</span></p>
            """
        }
        var branchRows = ""
        for b in summary.branches.prefix(50) {
            branchRows += "<li><code>\(htmlEscape(b))</code></li>\n"
        }
        if summary.branches.count > 50 {
            branchRows += "<li class=\"muted\">… \(summary.branches.count - 50) more</li>"
        }
        let descBlock = description.map { "<p>\(htmlEscape($0))</p>" } ?? ""
        let body = """
        <p><a href="/ui">← all</a> · <a href="/ui/\(htmlEscape(user))">\(htmlEscape(user))</a></p>
        <h1>\(htmlEscape(user))/\(htmlEscape(repo)) \(visBadge)</h1>
        \(descBlock)
        <div class="tabs">
          <a class="tab tab-active" href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))">overview</a>
          <a class="tab" href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))/commits">commits</a>
          <a class="tab" href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))/issues">issues (\(issues))</a>
          <a class="tab" href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))/pulls">pulls (\(prs))</a>
          <a class="tab" href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))/releases">releases (\(releases))</a>
        </div>
        \(headSection)
        <h3>clone</h3>
        <pre>git clone http://\(htmlEscape(req.headers.first(name: .host) ?? "localhost"))/\(htmlEscape(user))/\(htmlEscape(repo)).git</pre>
        <h3>branches (\(summary.branchCount))</h3>
        <ul>\(branchRows)</ul>
        """
        return htmlResponse(title: "\(user)/\(repo) · giteax", body: body, viewer: viewer)
    }

    // MARK: - GET /ui/:user/:repo/commits

    app.get("ui", ":user", ":repo", "commits") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        try await gateRead(req, user: user, repo: repo)
        let viewer = await currentIdentityName(req)
        let queryRef = req.query[String.self, at: "ref"]
        let summaryHead: String? = try? await runBlocking { try service.summary(user: user, repo: repo).headBranch }
        let ref = queryRef ?? summaryHead ?? "main"
        let limit = 50
        let commits: [RepositoryService.CommitInfo]
        do {
            commits = try await runBlocking { try service.log(user: user, repo: repo, ref: ref, limit: limit) }
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        var rows = ""
        for c in commits {
            rows += """
            <tr>
              <td class="mono">\(htmlEscape(String(c.id.prefix(8))))</td>
              <td>\(htmlEscape(c.summary))</td>
              <td class="muted">\(htmlEscape(c.authorName))</td>
              <td class=\"muted\">\(htmlEscape(fmtDate(c.date)))</td>
            </tr>
            """
        }
        if rows.isEmpty {
            rows = "<tr><td colspan=\"4\" class=\"muted\">no commits on \(htmlEscape(ref))</td></tr>"
        }
        let body = """
        <p><a href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))">← \(htmlEscape(user))/\(htmlEscape(repo))</a></p>
        <h1>commits · <code>\(htmlEscape(ref))</code></h1>
        <table class="commits">
          <thead><tr><th>oid</th><th>summary</th><th>author</th><th>date</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return htmlResponse(title: "commits · \(user)/\(repo)", body: body, viewer: viewer)
    }

    // MARK: - GET /ui/:user/:repo/issues

    app.get("ui", ":user", ":repo", "issues") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        try await gateRead(req, user: user, repo: repo)
        let viewer = await currentIdentityName(req)
        let stateFilter = req.query[String.self, at: "state"] ?? "open"
        let all = (try? await issueStore.list(user: user, repo: repo, limit: 9999)) ?? []
        let filtered = stateFilter == "all" ? all : all.filter { $0.state.rawValue == stateFilter }
        var rows = ""
        for i in filtered.sorted(by: { $0.number > $1.number }) {
            let st = i.state == .open ? "<span class=\"badge badge-open\">open</span>" : "<span class=\"badge badge-closed\">closed</span>"
            rows += """
            <tr>
              <td class=\"mono\">#\(i.number)</td>
              <td>\(htmlEscape(i.title))</td>
              <td>\(st)</td>
              <td class=\"muted\">\(htmlEscape(i.authorName))</td>
              <td class=\"muted\">\(htmlEscape(fmtDate(i.createdAt)))</td>
            </tr>
            """
        }
        if rows.isEmpty {
            rows = "<tr><td colspan=\"5\" class=\"muted\">no issues match state=\(htmlEscape(stateFilter))</td></tr>"
        }
        let body = """
        <p><a href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))">← \(htmlEscape(user))/\(htmlEscape(repo))</a></p>
        <h1>issues · <span class="muted">\(htmlEscape(user))/\(htmlEscape(repo))</span></h1>
        <p class="muted">filter:
          <a href="?state=open">open</a> ·
          <a href="?state=closed">closed</a> ·
          <a href="?state=all">all</a>
          (showing <b>\(htmlEscape(stateFilter))</b>)
        </p>
        <table class="commits">
          <thead><tr><th>#</th><th>title</th><th>state</th><th>author</th><th>created</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return htmlResponse(title: "issues · \(user)/\(repo)", body: body, viewer: viewer)
    }

    // MARK: - GET /ui/:user/:repo/pulls

    app.get("ui", ":user", ":repo", "pulls") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        try await gateRead(req, user: user, repo: repo)
        let viewer = await currentIdentityName(req)
        let stateFilter = req.query[String.self, at: "state"] ?? "open"
        let all = (try? await prStore.list(user: user, repo: repo, limit: 9999)) ?? []
        let filtered = stateFilter == "all" ? all : all.filter { $0.state.rawValue == stateFilter }
        var rows = ""
        for p in filtered.sorted(by: { $0.number > $1.number }) {
            let st = badgeForPRState(p.state.rawValue)
            rows += """
            <tr>
              <td class=\"mono\">#\(p.number)</td>
              <td>\(htmlEscape(p.title))</td>
              <td>\(st)</td>
              <td class=\"mono\"><code>\(htmlEscape(p.headBranch))</code> \u{2192} <code>\(htmlEscape(p.baseBranch))</code></td>
              <td class="muted">\(htmlEscape(p.authorName))</td>
            </tr>
            """
        }
        if rows.isEmpty {
            rows = "<tr><td colspan=\"5\" class=\"muted\">no PRs match state=\(htmlEscape(stateFilter))</td></tr>"
        }
        let body = """
        <p><a href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))">← \(htmlEscape(user))/\(htmlEscape(repo))</a></p>
        <h1>pull requests · <span class="muted">\(htmlEscape(user))/\(htmlEscape(repo))</span></h1>
        <p class="muted">filter:
          <a href="?state=open">open</a> ·
          <a href="?state=merged">merged</a> ·
          <a href="?state=closed">closed</a> ·
          <a href="?state=all">all</a>
          (showing <b>\(htmlEscape(stateFilter))</b>)
        </p>
        <table class="commits">
          <thead><tr><th>#</th><th>title</th><th>state</th><th>head → base</th><th>author</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return htmlResponse(title: "pulls · \(user)/\(repo)", body: body, viewer: viewer)
    }

    // MARK: - GET /ui/:user/:repo/releases

    app.get("ui", ":user", ":repo", "releases") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user or :repo")
        }
        try await gateRead(req, user: user, repo: repo)
        let viewer = await currentIdentityName(req)
        let all = (try? await releaseStore.list(user: user, repo: repo)) ?? []
        var rows = ""
        for r in all.sorted(by: { $0.createdAt > $1.createdAt }) {
            var assetList = ""
            for a in r.assets {
                let href = "/api/repos/\(user)/\(repo)/releases/\(r.tag)/assets/\(a.filename)"
                assetList += "<li><a href=\"\(href)\">\(htmlEscape(a.filename))</a> <span class=\"muted\">(\(a.size) bytes)</span></li>"
            }
            let assetsBlock = assetList.isEmpty ? "<span class=\"muted\">no assets</span>" : "<ul>\(assetList)</ul>"
            let prereleaseBadge = r.prerelease ? "<span class=\"badge badge-open\">prerelease</span>" : ""
            let draftBadge = r.draft ? "<span class=\"badge badge-closed\">draft</span>" : ""
            let displayName = r.name.isEmpty ? r.tag : r.name
            rows += """
            <tr>
              <td class="mono"><code>\(htmlEscape(r.tag))</code></td>
              <td>\(htmlEscape(displayName)) \(prereleaseBadge) \(draftBadge)</td>
              <td>\(assetsBlock)</td>
              <td class="muted">\(htmlEscape(r.authorName))</td>
              <td class="muted">\(htmlEscape(fmtDate(r.createdAt)))</td>
            </tr>
            """
        }
        if rows.isEmpty {
            rows = "<tr><td colspan=\"5\" class=\"muted\">no releases yet</td></tr>"
        }
        let body = """
        <p><a href="/ui/\(htmlEscape(user))/\(htmlEscape(repo))">← \(htmlEscape(user))/\(htmlEscape(repo))</a></p>
        <h1>releases · <span class="muted">\(htmlEscape(user))/\(htmlEscape(repo))</span></h1>
        <table class="commits">
          <thead><tr><th>tag</th><th>name</th><th>assets</th><th>author</th><th>created</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return htmlResponse(title: "releases · \(user)/\(repo)", body: body, viewer: viewer)
    }
}

// MARK: - Filesystem discovery (used for landing page)

/// Walks `<root>/<user>/<repo>.git` two levels deep. Hidden dirs and dirs
/// without a `.git` suffix on the inner level are ignored. Cheap enough
/// to invoke on every /ui request -- bounded by user count.
private func discoverRepoPairs(rootURL: URL) -> [(user: String, repo: String)] {
    let fm = FileManager.default
    var pairs: [(String, String)] = []
    guard let users = try? fm.contentsOfDirectory(atPath: rootURL.path) else { return [] }
    for user in users where !user.hasPrefix(".") {
        let userURL = rootURL.appendingPathComponent(user, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: userURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let entries = try? fm.contentsOfDirectory(atPath: userURL.path) else { continue }
        for e in entries where e.hasSuffix(".git") {
            let repo = String(e.dropLast(4))   // strip ".git"
            guard !repo.isEmpty else { continue }
            pairs.append((user, repo))
        }
    }
    return pairs
}

// MARK: - HTML helpers

private func htmlResponse(title: String, body: String, viewer: String?) -> Response {
    let viewerLink: String
    if let v = viewer, !v.isEmpty {
        viewerLink = "<span class=\"muted\">signed in as <b>\(htmlEscape(v))</b></span>"
    } else {
        viewerLink = "<span class=\"muted\">anonymous</span>"
    }
    let page = """
    <!doctype html>
    <html lang="en"><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>\(htmlEscape(title))</title>
      <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
               margin: 0 auto; padding: 1.5rem; max-width: 980px; line-height: 1.45; }
        h1 { margin-top: 0; }
        h1 code, p code, td code { font-family: ui-monospace, "Cascadia Code", Menlo, monospace; }
        a { color: #0a66c2; text-decoration: none; }
        a:hover { text-decoration: underline; }
        nav.top { display: flex; gap: 1rem; align-items: center; border-bottom: 1px solid #d0d7de;
                  padding-bottom: 0.5rem; margin-bottom: 1rem; }
        nav.top a.brand { font-weight: 700; font-size: 1.1rem; color: inherit; }
        nav.top .right { margin-left: auto; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #d0d7de33; vertical-align: top; }
        thead th { background: #f6f8fa22; }
        .muted { color: #6e7781; }
        .mono { font-family: ui-monospace, "Cascadia Code", Menlo, monospace; }
        pre { background: #f6f8fa22; padding: 0.6rem 0.9rem; border-radius: 6px; overflow: auto;
              border: 1px solid #d0d7de33; }
        .tabs { display: flex; gap: 0.4rem; margin: 0.8rem 0 1.2rem 0; border-bottom: 1px solid #d0d7de; }
        .tab { padding: 0.35rem 0.8rem; border-radius: 6px 6px 0 0; color: inherit; }
        .tab:hover { background: #f6f8fa44; text-decoration: none; }
        .tab-active { background: #f6f8fa66; font-weight: 600; border: 1px solid #d0d7de; border-bottom-color: transparent; }
        .badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 0.8rem;
                 background: #d0d7de44; }
        .badge-public { background: #1f883d22; color: #1a7f37; }
        .badge-internal { background: #bf871922; color: #9a6700; }
        .badge-private { background: #cf222e22; color: #cf222e; }
        .badge-open { background: #1f883d22; color: #1a7f37; }
        .badge-closed { background: #8250df22; color: #6f42c1; }
        .badge-merged { background: #8250df22; color: #6f42c1; }
        @media (prefers-color-scheme: dark) {
          body { background: #0d1117; color: #c9d1d9; }
          a { color: #58a6ff; }
          nav.top { border-bottom-color: #30363d; }
          th, td { border-bottom-color: #30363d33; }
          thead th { background: #161b2266; }
          pre { background: #161b22; border-color: #30363d; }
          .tabs { border-bottom-color: #30363d; }
          .tab-active { background: #161b22; border-color: #30363d; }
        }
      </style>
    </head><body>
      <nav class="top">
        <a class="brand" href="/ui">giteax</a>
        <a href="/version">version</a>
        <a href="/health">health</a>
        <span class="right">\(viewerLink)</span>
      </nav>
      \(body)
    </body></html>
    """
    let r = Response(status: .ok)
    r.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    r.body = .init(string: page)
    return r
}

private func visibilityBadge(_ vis: String) -> String {
    switch vis {
    case "public":   return "<span class=\"badge badge-public\">public</span>"
    case "internal": return "<span class=\"badge badge-internal\">internal</span>"
    case "private":  return "<span class=\"badge badge-private\">private</span>"
    default:         return "<span class=\"badge\">\(htmlEscape(vis))</span>"
    }
}

private func badgeForPRState(_ s: String) -> String {
    switch s {
    case "open":   return "<span class=\"badge badge-open\">open</span>"
    case "merged": return "<span class=\"badge badge-merged\">merged</span>"
    case "closed": return "<span class=\"badge badge-closed\">closed</span>"
    default:       return "<span class=\"badge\">\(htmlEscape(s))</span>"
    }
}

/// Minimal HTML escape covering & < > " '. Sufficient for attribute-and-
/// content escaping on a single page (no user-controlled URLs land inside
/// `<script>` blocks, so we don't need a fancier escaper).
private func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&":  out += "&amp;"
        case "<":  out += "&lt;"
        case ">":  out += "&gt;"
        case "\"": out += "&quot;"
        case "'":  out += "&#39;"
        default:   out.append(ch)
        }
    }
    return out
}
