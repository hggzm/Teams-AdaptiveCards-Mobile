// hggz/giteax -- Phase 25: code search (lightweight, in-memory).
//
// Walks the tree of a repo's default branch (or a query-specified ref)
// and case-insensitively substring-matches the query against the text
// content of each blob it visits. Returns up to N hits, each carrying
// the matching path + a short snippet of the matching line.
//
// Trade-offs (v0):
//
//   - Walks the libgit2 tree on every request. Bounded by file count
//     and per-file size (limits below). For small/medium personal
//     repos that's fine; for repos with 50k+ files we'd want an FTS5
//     index (see swift-sqlite-cross-platform memory note for the
//     vendored Csqlite3 recipe).
//   - No tokenisation, no relevance scoring. Substring only.
//   - Binary blobs skipped via existing libgit2 binary detection.
//   - Result snippet is the first matching line, trimmed to 200 chars.
//
// Endpoint:
//
//   GET /api/repos/:user/:repo/search/code?q=<text>[&ref=<branch>][&limit=<n>][&max_files=<n>]
//
// Visibility: gated by AccessController.requireRead like the rest of
// the repo browse surface.

import Vapor
import SwiftGitX
import Foundation

func registerCodeSearchRoutes(
    _ app: Application,
    service: RepositoryService,
    access: AccessController?,
    codeIndex: CodeIndex? = nil
) {
    let pool = app.threadPool
    @Sendable
    func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await pool.runIfActive(work)
    }

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

    app.get("api", "repos", ":user", ":repo", "search", "code") { req async throws -> Response in
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        let q = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw Abort(.badRequest, reason: "missing query parameter `q`") }
        guard q.count <= 200 else { throw Abort(.badRequest, reason: "query too long (max 200 chars)") }

        try await gateRead(req, user: user, repo: repo)

        // Resolve the ref: explicit query param wins, else default branch
        // via summary().
        let refOverride = req.query[String.self, at: "ref"]
        let limit = clamp(Int(req.query[String.self, at: "limit"] ?? "") ?? 50, lo: 1, hi: 500)
        let maxFiles = clamp(Int(req.query[String.self, at: "max_files"] ?? "") ?? 5000, lo: 1, hi: 50_000)

        let result: SearchResult
        // Phase 29: prefer the FTS5 index when available AND no explicit
        // ref was requested (the index always tracks the default branch).
        // For ?ref= queries fall back to the in-memory walker so users
        // can search a non-default branch ad-hoc.
        if let codeIndex, refOverride == nil {
            do {
                let idx = try await codeIndex.search(user: user, repo: repo, query: q, limit: limit)
                let truncated = idx.count >= limit
                result = SearchResult(
                    user: user, repo: repo, ref: idx.ref,
                    query: q, visitedFiles: idx.count,
                    truncated: truncated, count: idx.count,
                    hits: idx.hits.map { h in
                        CodeHit(path: h.path, line: 0, snippet: h.snippet, oid: h.oid, size: h.size)
                    }
                )
            } catch {
                // Index unavailable / broken -> fall back to walker.
                req.logger.warning("[code-search] index failed for \(user)/\(repo): \(error); falling back to walker")
                result = try await runBlocking {
                    try CodeScan.scan(
                        service: service,
                        user: user, repo: repo,
                        refOverride: refOverride,
                        query: q,
                        limit: limit,
                        maxFiles: maxFiles
                    )
                }
            }
        } else {
            result = try await runBlocking {
                try CodeScan.scan(
                    service: service,
                    user: user, repo: repo,
                    refOverride: refOverride,
                    query: q,
                    limit: limit,
                    maxFiles: maxFiles
                )
            }
        }
        let res = Response(status: .ok)
        try res.content.encode(result, as: .json)
        return res
    }
}

private enum CodeScan {
    static func scan(
        service: RepositoryService,
        user: String, repo: String,
        refOverride: String?,
        query: String,
        limit: Int,
        maxFiles: Int
    ) throws -> SearchResult {
        // Resolve ref. Default-branch fallback.
        let summary: RepositoryService.Summary
        do {
            summary = try service.summary(user: user, repo: repo)
        } catch let e as RepositoryService.LookupError {
            throw Abort(e.status, reason: e.reason)
        }
        let resolvedRef: String
        if let refOverride { resolvedRef = refOverride }
        else if let head = summary.headBranch { resolvedRef = head }
        else { throw Abort(.notFound, reason: "no default branch to search (unborn HEAD)") }

        let needle = query.lowercased()
        var hits: [CodeHit] = []
        var visited = 0
        var stack: [String] = [""]    // path prefixes to walk

        // Each iteration pulls a directory off the stack and lists it.
        // Subdirectories get pushed; blobs get inspected.
        while let dirPath = stack.popLast() {
            if visited >= maxFiles { break }
            if hits.count >= limit { break }
            let listing: RepositoryService.TreeListing
            do {
                listing = try service.tree(user: user, repo: repo, ref: resolvedRef, path: dirPath)
            } catch let e as RepositoryService.LookupError {
                // If the user supplied a bogus ref via query string, surface 404.
                if dirPath.isEmpty {
                    throw Abort(e.status, reason: e.reason)
                } else {
                    continue
                }
            } catch {
                continue
            }
            for entry in listing.entries {
                if visited >= maxFiles { break }
                if hits.count >= limit { break }
                let childPath = dirPath.isEmpty ? entry.name : "\(dirPath)/\(entry.name)"
                switch entry.kind {
                case "tree":
                    stack.append(childPath)
                case "blob", "blobExecutable":
                    visited += 1
                    if (entry.size ?? 0) > 1_000_000 { continue }   // skip > 1 MiB
                    let blobResult: (RepositoryService.BlobInfo, Data)
                    do {
                        blobResult = try service.blob(user: user, repo: repo, ref: resolvedRef, path: childPath)
                    } catch {
                        continue
                    }
                    let (info, data) = blobResult
                    if info.isBinary { continue }
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    let textLower = text.lowercased()
                    guard textLower.contains(needle) else { continue }
                    // Find the first matching line + line number for snippet.
                    var lineNo = 0
                    var snippet = ""
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        lineNo += 1
                        if line.lowercased().contains(needle) {
                            snippet = String(line.prefix(200))
                            break
                        }
                    }
                    hits.append(CodeHit(
                        path: childPath,
                        line: lineNo,
                        snippet: snippet,
                        oid: info.oid,
                        size: info.size
                    ))
                default:
                    continue
                }
            }
        }

        return SearchResult(
            user: user, repo: repo, ref: resolvedRef,
            query: query,
            visitedFiles: visited,
            truncated: (visited >= maxFiles) || (hits.count >= limit),
            count: hits.count,
            hits: hits
        )
    }
}

private struct CodeHit: Content {
    let path: String
    let line: Int
    let snippet: String
    let oid: String
    let size: Int
}

private struct SearchResult: Content {
    let user: String
    let repo: String
    let ref: String
    let query: String
    let visitedFiles: Int
    let truncated: Bool
    let count: Int
    let hits: [CodeHit]
}

private func clamp(_ x: Int, lo: Int, hi: Int) -> Int { max(lo, min(hi, x)) }
