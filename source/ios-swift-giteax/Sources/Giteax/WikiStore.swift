// hggz/giteax -- Phase 22: per-repo Wiki.
//
// Tiny markdown wiki living next to issues / PRs / releases. Each repo
// has one wiki with multiple named pages. Pages are JSON-stored
// alongside the other envelopes (no separate git repo for the wiki --
// that's a real Gitea-feature but it's overkill here).
//
// Endpoints:
//
//   GET    /api/repos/:user/:repo/wiki/pages                      (read)
//   GET    /api/repos/:user/:repo/wiki/pages/:slug                (read)
//   PUT    /api/repos/:user/:repo/wiki/pages/:slug                (write)
//          body: { title?, content }   (creates or updates)
//   DELETE /api/repos/:user/:repo/wiki/pages/:slug                (write)
//
// Slug grammar: `[A-Za-z0-9._-]{1,128}`. URL-encoded slashes are
// rejected -- we keep the wiki flat for the v0 since hierarchical
// pages add ambiguity around link rewriting.
//
// Storage: <root>/.giteax/repos/<user>/<repo>/wiki.json with the same
// temp+move atomic-write triple as the other stores.
//
// Access: read on listing/fetch follows the standard ACL gates;
// write requires push-authed user with write permission on the repo.

import Vapor
import Foundation

actor WikiStore {

    struct Page: Sendable, Codable {
        let slug: String
        var title: String
        var content: String
        let authorName: String
        let createdAt: Date
        var updatedAt: Date
        var updatedBy: String
        /// Monotonic update counter; bumped on every PUT. Cheap conflict
        /// detection for clients that want it.
        var revision: Int
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var pages: [Page]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case pageNotFound(slug: String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound:  .notFound
            case .pageNotFound:  .notFound
            case .invalidInput:  .badRequest
            case .ioFailed:      .internalServerError
            case .badEnvelope:   .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): "no repository at \(u)/\(r)"
            case .pageNotFound(let s):        "wiki page '\(s)' not found"
            case .invalidInput(let s):        "invalid wiki input: \(s)"
            case .ioFailed(let s):            "wiki I/O: \(s)"
            case .badEnvelope(let s):         "wiki envelope: \(s)"
            }
        }
    }

    private let root: URL

    init(root: URL) {
        self.root = root
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos",   isDirectory: true)
            .appendingPathComponent(user,      isDirectory: true)
            .appendingPathComponent(repo,      isDirectory: true)
            .appendingPathComponent("wiki.json", isDirectory: false)
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let url = envelopeURL(user: user, repo: repo)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Envelope(version: 1, pages: [])
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw StoreError.ioFailed("read \(url.path): \(error)") }
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(Envelope.self, from: data)
        } catch {
            throw StoreError.badEnvelope("\(error)")
        }
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let url = envelopeURL(user: user, repo: repo)
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw StoreError.ioFailed("mkdir: \(error)")
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do { data = try enc.encode(env) }
        catch { throw StoreError.ioFailed("encode: \(error)") }
        let tmp = parent.appendingPathComponent("wiki.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.ioFailed("persist: \(error)")
        }
    }

    func list(user: String, repo: String) throws -> [Page] {
        let env = try loadOrInit(user: user, repo: repo)
        return env.pages.sorted { $0.slug < $1.slug }
    }

    func get(user: String, repo: String, slug: String) throws -> Page {
        let env = try loadOrInit(user: user, repo: repo)
        guard let p = env.pages.first(where: { $0.slug == slug }) else {
            throw StoreError.pageNotFound(slug: slug)
        }
        return p
    }

    /// Upsert. Creates if missing; replaces title/content + bumps revision
    /// if exists.
    func upsert(
        user: String, repo: String,
        slug: String, title: String, content: String,
        by author: String
    ) throws -> Page {
        try Self.validateSlug(slug)
        guard !title.isEmpty else { throw StoreError.invalidInput("title is empty") }
        guard content.count <= 1_000_000 else {
            throw StoreError.invalidInput("page content exceeds 1 MiB")
        }
        var env = try loadOrInit(user: user, repo: repo)
        if let idx = env.pages.firstIndex(where: { $0.slug == slug }) {
            var p = env.pages[idx]
            p.title = title
            p.content = content
            p.updatedAt = Date()
            p.updatedBy = author
            p.revision += 1
            env.pages[idx] = p
            try persist(env, user: user, repo: repo)
            return p
        } else {
            let now = Date()
            let p = Page(
                slug: slug, title: title, content: content,
                authorName: author, createdAt: now, updatedAt: now,
                updatedBy: author, revision: 1
            )
            env.pages.append(p)
            try persist(env, user: user, repo: repo)
            return p
        }
    }

    func delete(user: String, repo: String, slug: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.pages.firstIndex(where: { $0.slug == slug }) else {
            throw StoreError.pageNotFound(slug: slug)
        }
        env.pages.remove(at: idx)
        try persist(env, user: user, repo: repo)
    }

    private static let allowedSlugChars: Set<Character> = {
        var s: Set<Character> = []
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" { s.insert(c) }
        return s
    }()

    static func validateSlug(_ s: String) throws {
        guard !s.isEmpty else { throw StoreError.invalidInput("slug is empty") }
        guard s.count <= 128 else { throw StoreError.invalidInput("slug too long (>128 chars)") }
        for ch in s where !allowedSlugChars.contains(ch) {
            throw StoreError.invalidInput("slug contains invalid character '\(ch)' (allowed: A-Za-z0-9._-)")
        }
        if s == "." || s == ".." {
            throw StoreError.invalidInput("slug must not be '.' or '..'")
        }
    }
}

// MARK: - Routes

func registerWikiRoutes(
    _ app: Application,
    store: WikiStore,
    pushAuth: GitPushBasicAuth?,
    access: AccessController?
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
    func gateWrite(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else { throw Abort(.serviceUnavailable, reason: "wiki writes disabled (no push auth)") }
        if let challenge = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            if let h = challenge.headers.first(name: .wwwAuthenticate) {
                headers.add(name: .wwwAuthenticate, value: h)
            }
            throw Abort(.unauthorized, headers: headers, reason: "authentication required for wiki writes")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write,
                    user: user, repo: repo,
                    scope: "editing the wiki"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    @Sendable
    func params(_ req: Request) throws -> (String, String) {
        guard let user = req.parameters.get("user"),
              let repo = req.parameters.get("repo")
        else { throw Abort(.badRequest, reason: "missing :user or :repo") }
        return (user, repo)
    }

    app.get("api", "repos", ":user", ":repo", "wiki", "pages") { req async throws -> Response in
        let (u, r) = try params(req)
        try await gateRead(req, user: u, repo: r)
        let pages = try await store.list(user: u, repo: r)
        let body = WikiListDTO(user: u, repo: r, count: pages.count, pages: pages.map(WikiPageDTO.from))
        let res = Response(status: .ok)
        try res.content.encode(body, as: .json)
        return res
    }

    app.get("api", "repos", ":user", ":repo", "wiki", "pages", ":slug") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let slug = req.parameters.get("slug") else {
            throw Abort(.badRequest, reason: "missing :slug")
        }
        try await gateRead(req, user: u, repo: r)
        do {
            let p = try await store.get(user: u, repo: r, slug: slug)
            let res = Response(status: .ok)
            try res.content.encode(WikiPageDTO.from(p), as: .json)
            return res
        } catch let e as WikiStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.put("api", "repos", ":user", ":repo", "wiki", "pages", ":slug") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let slug = req.parameters.get("slug") else {
            throw Abort(.badRequest, reason: "missing :slug")
        }
        let author = try await gateWrite(req, user: u, repo: r)
        let dto = try req.content.decode(WikiUpsertDTO.self)
        do {
            let p = try await store.upsert(
                user: u, repo: r,
                slug: slug,
                title: dto.title ?? slug,
                content: dto.content,
                by: author
            )
            let status: HTTPResponseStatus = (p.revision == 1) ? .created : .ok
            let res = Response(status: status)
            try res.content.encode(WikiPageDTO.from(p), as: .json)
            return res
        } catch let e as WikiStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "repos", ":user", ":repo", "wiki", "pages", ":slug") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let slug = req.parameters.get("slug") else {
            throw Abort(.badRequest, reason: "missing :slug")
        }
        _ = try await gateWrite(req, user: u, repo: r)
        do {
            try await store.delete(user: u, repo: r, slug: slug)
        } catch let e as WikiStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        return Response(status: .noContent)
    }
}

private struct WikiUpsertDTO: Content {
    let title: String?
    let content: String
}

private struct WikiPageDTO: Content {
    let slug: String
    let title: String
    let content: String
    let authorName: String
    let createdAt: Date
    let updatedAt: Date
    let updatedBy: String
    let revision: Int

    static func from(_ p: WikiStore.Page) -> WikiPageDTO {
        WikiPageDTO(
            slug: p.slug, title: p.title, content: p.content,
            authorName: p.authorName, createdAt: p.createdAt,
            updatedAt: p.updatedAt, updatedBy: p.updatedBy,
            revision: p.revision
        )
    }
}

private struct WikiListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let pages: [WikiPageDTO]
}
