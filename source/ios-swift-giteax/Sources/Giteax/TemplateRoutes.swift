import Foundation
import Vapor

/// Phase 47 -- per-repo issue / pull-request templates.
///
/// On-disk layout (lives under the same per-repo state dir as wiki /
/// issues / labels / etc., so `Phase 44` transfer + rename already
/// moves it for free):
///
///     <root>/.giteax/repos/<user>/<repo>/templates.json
///
/// Envelope:
///
///     {
///       "version": 1,
///       "issueTemplates": [ {name, title?, body, labels[], updatedAt, updatedBy} ],
///       "pullTemplates":  [ {name, title?, body, labels[], updatedAt, updatedBy} ]
///     }
///
/// Both kinds share the same `Template` shape; `kind` selects which
/// array they live in. Templates are NAME-keyed (segment-valid). At
/// most 32 of each kind per repo; body capped at 64 KiB.
actor TemplateStore {

    enum Kind: String, Sendable, Codable {
        case issue, pull
    }

    struct Template: Sendable, Codable {
        let name: String
        var title: String?
        var body: String
        var labels: [String]
        var updatedAt: Date
        var updatedBy: String
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var issueTemplates: [Template]
        var pullTemplates: [Template]
    }

    enum StoreError: Error, CustomStringConvertible {
        case ioFailed(String)
        case badEnvelope(String)
        case notFound(String)
        case invalidInput(String)
        case tooMany(Int)

        var description: String {
            switch self {
            case .ioFailed(let s):     "templates I/O: \(s)"
            case .badEnvelope(let s):  "templates envelope: \(s)"
            case .notFound(let s):     "no such template: \(s)"
            case .invalidInput(let s): "invalid input: \(s)"
            case .tooMany(let n):      "too many templates (max \(n) per kind per repo)"
            }
        }
    }

    static let maxPerKind = 32
    static let maxBodyBytes = 64 * 1024

    private let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: - Read

    func list(user: String, repo: String, kind: Kind) throws -> [Template] {
        let env = try loadOrInit(user: user, repo: repo)
        let arr = (kind == .issue) ? env.issueTemplates : env.pullTemplates
        return arr.sorted { $0.name < $1.name }
    }

    func get(user: String, repo: String, kind: Kind, name: String) throws -> Template {
        let env = try loadOrInit(user: user, repo: repo)
        let arr = (kind == .issue) ? env.issueTemplates : env.pullTemplates
        guard let t = arr.first(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        return t
    }

    // MARK: - Mutate

    @discardableResult
    func upsert(
        user: String, repo: String, kind: Kind,
        name: String, title: String?, body: String, labels: [String],
        by author: String
    ) throws -> Template {
        guard RepositoryService.validateSegment(name) else {
            throw StoreError.invalidInput("name must match [A-Za-z0-9][A-Za-z0-9._-]*")
        }
        if body.utf8.count > Self.maxBodyBytes {
            throw StoreError.invalidInput("body exceeds \(Self.maxBodyBytes) bytes")
        }
        let cleanLabels = labels
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let title, title.count > 256 {
            throw StoreError.invalidInput("title exceeds 256 characters")
        }
        var env = try loadOrInit(user: user, repo: repo)
        let now = Date()
        let t = Template(
            name: name, title: title, body: body, labels: cleanLabels,
            updatedAt: now, updatedBy: author
        )
        if kind == .issue {
            if let idx = env.issueTemplates.firstIndex(where: { $0.name == name }) {
                env.issueTemplates[idx] = t
            } else {
                if env.issueTemplates.count >= Self.maxPerKind {
                    throw StoreError.tooMany(Self.maxPerKind)
                }
                env.issueTemplates.append(t)
            }
        } else {
            if let idx = env.pullTemplates.firstIndex(where: { $0.name == name }) {
                env.pullTemplates[idx] = t
            } else {
                if env.pullTemplates.count >= Self.maxPerKind {
                    throw StoreError.tooMany(Self.maxPerKind)
                }
                env.pullTemplates.append(t)
            }
        }
        try persist(env, user: user, repo: repo)
        return t
    }

    func delete(user: String, repo: String, kind: Kind, name: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        if kind == .issue {
            guard let idx = env.issueTemplates.firstIndex(where: { $0.name == name }) else {
                throw StoreError.notFound(name)
            }
            env.issueTemplates.remove(at: idx)
        } else {
            guard let idx = env.pullTemplates.firstIndex(where: { $0.name == name }) else {
                throw StoreError.notFound(name)
            }
            env.pullTemplates.remove(at: idx)
        }
        try persist(env, user: user, repo: repo)
    }

    // MARK: - Eviction (Phase 44 transfer hook)

    /// No-op for now: this store reads from disk on every call, so a
    /// physical move + parent-dir rename is enough; there is no in-actor
    /// cache to invalidate. The method exists so callers in
    /// TransferRoutes can stay symmetric with the other stores.
    func evictRepo(user: String, repo: String) { /* nothing cached */ }

    // MARK: - Internals

    private func envelopeURL(user: String, repo: String) -> URL {
        root
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos",   isDirectory: true)
            .appendingPathComponent(user,      isDirectory: true)
            .appendingPathComponent(repo,      isDirectory: true)
            .appendingPathComponent("templates.json", isDirectory: false)
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let url = envelopeURL(user: user, repo: repo)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Envelope(version: 1, issueTemplates: [], pullTemplates: [])
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw StoreError.ioFailed("read: \(error)") }
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
        let tmp = parent.appendingPathComponent(
            "templates.json.tmp-\(ProcessInfo.processInfo.processIdentifier)"
        )
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
}

// MARK: - Routes

/// Phase 47 -- issue + PR template HTTP endpoints.
///
///   GET    /api/repos/:u/:r/templates                         (public; both kinds)
///   GET    /api/repos/:u/:r/templates/:kind                   (public; one kind)
///   GET    /api/repos/:u/:r/templates/:kind/:name             (public)
///   PUT    /api/repos/:u/:r/templates/:kind/:name             (write)
///       body: {title?, body, labels[]?}
///   DELETE /api/repos/:u/:r/templates/:kind/:name             (write)
///
///   :kind ∈ { "issue", "pull" }.
///
/// Reads gated via `AccessController.requireRead` (matches LabelRoutes).
/// Writes via pushAuth + `access.require(.write)`.
func registerTemplateRoutes(
    _ app: Application,
    templates: TemplateStore,
    pushAuth: GitPushBasicAuth?,
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
    func requireWrite(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth else {
            throw Abort(.forbidden, reason: "writes disabled (set GITEAX_ALLOW_PUSH=1)")
        }
        if let _ = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: headers, reason: "authentication required")
        }
        guard let name = req.storage[GitPushAuthedUserKey.self] else {
            throw Abort(.unauthorized, reason: "authenticated user missing")
        }
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .write, user: user, repo: repo,
                    scope: "writing templates"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }

    @Sendable
    func params(_ req: Request) throws -> (String, String) {
        guard let u = req.parameters.get("user"), let r = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user/:repo")
        }
        guard RepositoryService.validateSegment(u), RepositoryService.validateSegment(r) else {
            throw Abort(.badRequest, reason: "invalid user/repo segment")
        }
        return (u, r)
    }

    @Sendable
    func parseKind(_ req: Request) throws -> TemplateStore.Kind {
        guard let s = req.parameters.get("kind"),
              let k = TemplateStore.Kind(rawValue: s) else {
            throw Abort(.badRequest, reason: "kind must be 'issue' or 'pull'")
        }
        return k
    }

    // ── Reads ────────────────────────────────────────────────────────

    app.get("api", "repos", ":user", ":repo", "templates") { req async throws -> Response in
        let (u, r) = try params(req)
        try await gateRead(req, user: u, repo: r)
        let issues = try await templates.list(user: u, repo: r, kind: .issue)
        let pulls  = try await templates.list(user: u, repo: r, kind: .pull)
        let dto = TemplateListAllDTO(
            user: u, repo: r,
            issueTemplates: issues.map(TemplateDTO.from),
            pullTemplates:  pulls.map(TemplateDTO.from)
        )
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.get("api", "repos", ":user", ":repo", "templates", ":kind") { req async throws -> Response in
        let (u, r) = try params(req)
        let k = try parseKind(req)
        try await gateRead(req, user: u, repo: r)
        let arr = try await templates.list(user: u, repo: r, kind: k)
        let dto = TemplateListDTO(
            user: u, repo: r, kind: k.rawValue,
            count: arr.count, templates: arr.map(TemplateDTO.from)
        )
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    app.get("api", "repos", ":user", ":repo", "templates", ":kind", ":name") { req async throws -> Response in
        let (u, r) = try params(req)
        let k = try parseKind(req)
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        try await gateRead(req, user: u, repo: r)
        do {
            let t = try await templates.get(user: u, repo: r, kind: k, name: n)
            let resp = Response(status: .ok)
            try resp.content.encode(TemplateDTO.from(t), as: .json)
            return resp
        } catch TemplateStore.StoreError.notFound(let s) {
            throw Abort(.notFound, reason: "no such template: '\(s)'")
        }
    }

    // ── Writes ───────────────────────────────────────────────────────

    app.put("api", "repos", ":user", ":repo", "templates", ":kind", ":name") { req async throws -> Response in
        let (u, r) = try params(req)
        let k = try parseKind(req)
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        let author = try await requireWrite(req, user: u, repo: r)
        let body = try req.content.decode(TemplateUpsertDTO.self)
        do {
            let t = try await templates.upsert(
                user: u, repo: r, kind: k,
                name: n,
                title: body.title,
                body: body.body,
                labels: body.labels ?? [],
                by: author
            )
            let resp = Response(status: .ok)
            try resp.content.encode(TemplateDTO.from(t), as: .json)
            return resp
        } catch let e as TemplateStore.StoreError {
            switch e {
            case .invalidInput(let m): throw Abort(.badRequest, reason: m)
            case .tooMany(let n):      throw Abort(.payloadTooLarge, reason: "max \(n) templates per kind")
            case .notFound(let s):     throw Abort(.notFound, reason: "no such template: '\(s)'")
            default:                   throw Abort(.internalServerError, reason: e.description)
            }
        }
    }

    app.delete("api", "repos", ":user", ":repo", "templates", ":kind", ":name") { req async throws -> Response in
        let (u, r) = try params(req)
        let k = try parseKind(req)
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        _ = try await requireWrite(req, user: u, repo: r)
        do {
            try await templates.delete(user: u, repo: r, kind: k, name: n)
            return Response(status: .noContent)
        } catch TemplateStore.StoreError.notFound(let s) {
            throw Abort(.notFound, reason: "no such template: '\(s)'")
        }
    }
}

// MARK: - DTOs

private struct TemplateDTO: Content {
    let name: String
    let title: String?
    let body: String
    let labels: [String]
    let updatedAt: Date
    let updatedBy: String

    static func from(_ t: TemplateStore.Template) -> TemplateDTO {
        .init(name: t.name, title: t.title, body: t.body, labels: t.labels,
              updatedAt: t.updatedAt, updatedBy: t.updatedBy)
    }
}

private struct TemplateListDTO: Content {
    let user: String
    let repo: String
    let kind: String
    let count: Int
    let templates: [TemplateDTO]
}

private struct TemplateListAllDTO: Content {
    let user: String
    let repo: String
    let issueTemplates: [TemplateDTO]
    let pullTemplates: [TemplateDTO]
}

private struct TemplateUpsertDTO: Content {
    let title: String?
    let body: String
    let labels: [String]?
}
