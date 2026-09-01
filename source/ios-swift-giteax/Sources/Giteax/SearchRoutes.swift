// hggz/giteax -- Phase 18: search across issues + pull requests.
//
// In-memory grep over all repos visible to the caller. Two endpoints:
//
//   GET /api/search/issues?q=<text>&state=<open|closed|all>&limit=<n>
//   GET /api/search/pulls?q=<text>&state=<open|merged|closed|all>&limit=<n>
//
// Matching: case-insensitive substring of `q` against title + body
// (and against the issue author name). Returns the top `limit`
// matches (default 50, max 200) ordered by repo, then by number desc.
//
// Visibility: each candidate repo is gated through AccessController.
// requireRead -- private repos with no grant are silently skipped.
// On a public-only deployment with no access controller, all repos are
// considered visible.
//
// Code search is intentionally out of scope; that needs a real index
// (Phase 13+ pulls in the vendored Csqlite3 / FTS5 plan from the
// shared memory notes). Issue/PR text fits in memory comfortably.

import Vapor
import Foundation

func registerSearchRoutes(
    _ app: Application,
    rootURL: URL,
    metaStore: RepoMetaStore,
    issueStore: IssueStore,
    prStore: PullRequestStore,
    access: AccessController?
) {
    // MARK: - GET /api/search/issues

    app.get("api", "search", "issues") { req async throws -> Response in
        let q = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw Abort(.badRequest, reason: "missing query parameter `q`")
        }
        let stateFilter = (req.query[String.self, at: "state"] ?? "all").lowercased()
        guard ["all", "open", "closed"].contains(stateFilter) else {
            throw Abort(.badRequest, reason: "state must be all|open|closed")
        }
        let limit = clampSearch(Int(req.query[String.self, at: "limit"] ?? "") ?? 50)

        let viewer = await access?.identify(req)
        let repos = await visibleRepos(rootURL: rootURL, viewer: viewer, access: access)
        let needle = q.lowercased()

        var matches: [IssueMatchDTO] = []
        outer: for (u, r) in repos {
            let all = (try? await issueStore.list(user: u, repo: r, limit: 9999)) ?? []
            for issue in all {
                if stateFilter != "all" && issue.state.rawValue != stateFilter { continue }
                let hayTitle = issue.title.lowercased()
                let hayBody = issue.body.lowercased()
                let hayAuthor = issue.authorName.lowercased()
                guard hayTitle.contains(needle) || hayBody.contains(needle) || hayAuthor.contains(needle) else { continue }
                matches.append(IssueMatchDTO(
                    user: u, repo: r,
                    number: issue.number,
                    title: issue.title,
                    state: issue.state.rawValue,
                    authorName: issue.authorName,
                    createdAt: issue.createdAt,
                    updatedAt: issue.updatedAt,
                    labels: issue.labels
                ))
                if matches.count >= limit { break outer }
            }
        }
        let body = IssueSearchResponseDTO(query: q, state: stateFilter, count: matches.count, matches: matches)
        let res = Response(status: .ok)
        try res.content.encode(body, as: .json)
        return res
    }

    // MARK: - GET /api/search/pulls

    app.get("api", "search", "pulls") { req async throws -> Response in
        let q = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw Abort(.badRequest, reason: "missing query parameter `q`")
        }
        let stateFilter = (req.query[String.self, at: "state"] ?? "all").lowercased()
        guard ["all", "open", "merged", "closed"].contains(stateFilter) else {
            throw Abort(.badRequest, reason: "state must be all|open|merged|closed")
        }
        let limit = clampSearch(Int(req.query[String.self, at: "limit"] ?? "") ?? 50)

        let viewer = await access?.identify(req)
        let repos = await visibleRepos(rootURL: rootURL, viewer: viewer, access: access)
        let needle = q.lowercased()

        var matches: [PRMatchDTO] = []
        outer: for (u, r) in repos {
            let all = (try? await prStore.list(user: u, repo: r, limit: 9999)) ?? []
            for pr in all {
                if stateFilter != "all" && pr.state.rawValue != stateFilter { continue }
                let hayTitle = pr.title.lowercased()
                let hayBody = pr.body.lowercased()
                let hayAuthor = pr.authorName.lowercased()
                guard hayTitle.contains(needle) || hayBody.contains(needle) || hayAuthor.contains(needle) else { continue }
                matches.append(PRMatchDTO(
                    user: u, repo: r,
                    number: pr.number,
                    title: pr.title,
                    state: pr.state.rawValue,
                    authorName: pr.authorName,
                    headBranch: pr.headBranch,
                    baseBranch: pr.baseBranch,
                    createdAt: pr.createdAt,
                    updatedAt: pr.updatedAt
                ))
                if matches.count >= limit { break outer }
            }
        }
        let body = PRSearchResponseDTO(query: q, state: stateFilter, count: matches.count, matches: matches)
        let res = Response(status: .ok)
        try res.content.encode(body, as: .json)
        return res
    }
}

// MARK: - Helpers

private func clampSearch(_ x: Int) -> Int { max(1, min(200, x)) }

/// Discover all `<root>/<user>/<repo>.git` pairs and filter to those
/// the viewer can read. Returns sorted (user, repo) tuples.
private func visibleRepos(
    rootURL: URL,
    viewer: AuthIdentity?,
    access: AccessController?
) async -> [(user: String, repo: String)] {
    let fm = FileManager.default
    var pairs: [(String, String)] = []
    guard let users = try? fm.contentsOfDirectory(atPath: rootURL.path) else { return [] }
    for user in users where !user.hasPrefix(".") {
        let userURL = rootURL.appendingPathComponent(user, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: userURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let entries = try? fm.contentsOfDirectory(atPath: userURL.path) else { continue }
        for e in entries where e.hasSuffix(".git") {
            let repo = String(e.dropLast(4))
            guard !repo.isEmpty else { continue }
            pairs.append((user, repo))
        }
    }
    pairs.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    guard let access else { return pairs }
    let id = viewer ?? AuthIdentity(name: nil, isGlobalAdmin: false)
    var out: [(String, String)] = []
    for (u, r) in pairs {
        do {
            try await access.requireRead(id, user: u, repo: r, scope: "this repository")
            out.append((u, r))
        } catch {
            // skip non-visible
        }
    }
    return out
}

// MARK: - DTOs

private struct IssueMatchDTO: Content {
    let user: String
    let repo: String
    let number: Int
    let title: String
    let state: String
    let authorName: String
    let createdAt: Date
    let updatedAt: Date
    let labels: [String]
}

private struct IssueSearchResponseDTO: Content {
    let query: String
    let state: String
    let count: Int
    let matches: [IssueMatchDTO]
}

private struct PRMatchDTO: Content {
    let user: String
    let repo: String
    let number: Int
    let title: String
    let state: String
    let authorName: String
    let headBranch: String
    let baseBranch: String
    let createdAt: Date
    let updatedAt: Date
}

private struct PRSearchResponseDTO: Content {
    let query: String
    let state: String
    let count: Int
    let matches: [PRMatchDTO]
}
