// hggz/giteax -- Phase 26: generic per-repo package registry.
//
// Stores typed package artifacts ({npm, swift, generic, ...}) by name
// + version, with one or more files per version. Modelled close to
// releases (Phase 13) but distinct because:
//
//   - Packages aren't tied to git tags; they have free-form versions.
//   - A package can have multiple files (tarball + checksum + manifest).
//   - The path shape matches what real package managers expect:
//     GET /api/repos/:u/:r/packages/:type/:name/:version/files/:file
//
// Endpoints:
//
//   GET    /api/repos/:u/:r/packages                                          (read)
//   GET    /api/repos/:u/:r/packages/:type                                    (read)
//   GET    /api/repos/:u/:r/packages/:type/:name                              (read)
//   GET    /api/repos/:u/:r/packages/:type/:name/:version                     (read)
//   GET    /api/repos/:u/:r/packages/:type/:name/:version/files/:file         (read)
//   POST   /api/repos/:u/:r/packages/:type/:name/:version                     (write+)
//          body: { description?, manifest? }
//   DELETE /api/repos/:u/:r/packages/:type/:name/:version                     (admin)
//   PUT    /api/repos/:u/:r/packages/:type/:name/:version/files/:file         (write+) raw bytes
//   DELETE /api/repos/:u/:r/packages/:type/:name/:version/files/:file         (write+)
//
// Type/name/version/file grammar: [A-Za-z0-9._+-]{1,128}. Forbids
// slashes, dots-only, empty.
//
// Storage:
//   <root>/.giteax/repos/<u>/<r>/packages.json
//   <root>/.giteax/repos/<u>/<r>/packages/<type>/<name>/<version>/<file>
//
// Authoring policy:
//   - Initial POST creates the version record (writers).
//   - Subsequent PUT uploads file bytes (writers). Files can be
//     replaced; deleting is also writer.
//   - DELETE of the whole version requires admin (mirrors releases).
//   - 256 MiB cap per file (same as release assets).

import Vapor
import Foundation

private let pkgFileMaxBytes = 256 * 1024 * 1024

actor PackageStore {

    struct File: Sendable, Codable {
        let filename: String
        let size: Int
        let contentType: String
        let uploadedAt: Date
        let uploadedBy: String
    }

    struct Version: Sendable, Codable {
        let type: String
        let name: String
        let version: String
        var description: String?
        var manifest: String?     // free-form, e.g. package.json string
        let authorName: String
        let createdAt: Date
        var updatedAt: Date
        var files: [File]
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var packages: [Version]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case versionNotFound(type: String, name: String, version: String)
        case fileNotFound(filename: String)
        case alreadyExists(type: String, name: String, version: String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound:    .notFound
            case .versionNotFound: .notFound
            case .fileNotFound:    .notFound
            case .alreadyExists:   .conflict
            case .invalidInput:    .badRequest
            case .ioFailed:        .internalServerError
            case .badEnvelope:     .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r):                "no repository at \(u)/\(r)"
            case .versionNotFound(let t, let n, let v):      "package \(t)/\(n)@\(v) not found"
            case .fileNotFound(let f):                       "package file '\(f)' not found"
            case .alreadyExists(let t, let n, let v):        "package \(t)/\(n)@\(v) already exists"
            case .invalidInput(let s):                       "invalid package input: \(s)"
            case .ioFailed(let s):                           "package I/O: \(s)"
            case .badEnvelope(let s):                        "package envelope: \(s)"
            }
        }
    }

    private let root: URL

    init(root: URL) { self.root = root }

    // MARK: - Disk layout

    private func envelopeURL(user: String, repo: String) -> URL {
        root
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos",   isDirectory: true)
            .appendingPathComponent(user,      isDirectory: true)
            .appendingPathComponent(repo,      isDirectory: true)
            .appendingPathComponent("packages.json", isDirectory: false)
    }

    private func filePath(user: String, repo: String, type: String, name: String, version: String, filename: String) -> URL {
        root
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos",   isDirectory: true)
            .appendingPathComponent(user,      isDirectory: true)
            .appendingPathComponent(repo,      isDirectory: true)
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(type,      isDirectory: true)
            .appendingPathComponent(name,      isDirectory: true)
            .appendingPathComponent(version,   isDirectory: true)
            .appendingPathComponent(filename,  isDirectory: false)
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let url = envelopeURL(user: user, repo: repo)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Envelope(version: 1, packages: [])
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
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw StoreError.ioFailed("mkdir: \(error)") }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do { data = try enc.encode(env) } catch { throw StoreError.ioFailed("encode: \(error)") }
        let tmp = parent.appendingPathComponent("packages.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

    // MARK: - Validation

    private static let allowedSegmentChars: Set<Character> = {
        var s: Set<Character> = []
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-" { s.insert(c) }
        return s
    }()

    private static func validateSegment(_ s: String, fieldName: String) throws {
        guard !s.isEmpty else { throw StoreError.invalidInput("\(fieldName) is empty") }
        guard s.count <= 128 else { throw StoreError.invalidInput("\(fieldName) too long (>128)") }
        if s == "." || s == ".." { throw StoreError.invalidInput("\(fieldName) is reserved") }
        for ch in s where !allowedSegmentChars.contains(ch) {
            throw StoreError.invalidInput("\(fieldName) contains invalid char '\(ch)'")
        }
    }

    // MARK: - Public API

    func list(user: String, repo: String, type: String? = nil, name: String? = nil) throws -> [Version] {
        let env = try loadOrInit(user: user, repo: repo)
        var out = env.packages
        if let t = type { out = out.filter { $0.type == t } }
        if let n = name { out = out.filter { $0.name == n } }
        return out.sorted { ($0.type, $0.name, $0.version) < ($1.type, $1.name, $1.version) }
    }

    func get(user: String, repo: String, type: String, name: String, version: String) throws -> Version {
        let env = try loadOrInit(user: user, repo: repo)
        guard let v = env.packages.first(where: { $0.type == type && $0.name == name && $0.version == version }) else {
            throw StoreError.versionNotFound(type: type, name: name, version: version)
        }
        return v
    }

    @discardableResult
    func create(
        user: String, repo: String,
        type: String, name: String, version: String,
        description: String?, manifest: String?,
        by author: String
    ) throws -> Version {
        try Self.validateSegment(type, fieldName: "type")
        try Self.validateSegment(name, fieldName: "name")
        try Self.validateSegment(version, fieldName: "version")
        if let m = manifest, m.count > 1_000_000 {
            throw StoreError.invalidInput("manifest > 1 MiB")
        }
        var env = try loadOrInit(user: user, repo: repo)
        if env.packages.contains(where: { $0.type == type && $0.name == name && $0.version == version }) {
            throw StoreError.alreadyExists(type: type, name: name, version: version)
        }
        let now = Date()
        let v = Version(
            type: type, name: name, version: version,
            description: description, manifest: manifest,
            authorName: author, createdAt: now, updatedAt: now,
            files: []
        )
        env.packages.append(v)
        try persist(env, user: user, repo: repo)
        return v
    }

    func delete(user: String, repo: String, type: String, name: String, version: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.packages.firstIndex(where: { $0.type == type && $0.name == name && $0.version == version }) else {
            throw StoreError.versionNotFound(type: type, name: name, version: version)
        }
        // Remove files on disk best-effort.
        for f in env.packages[idx].files {
            let url = filePath(user: user, repo: repo, type: type, name: name, version: version, filename: f.filename)
            try? FileManager.default.removeItem(at: url)
        }
        // Remove the version dir entirely (cleans empty subdirs).
        let versionDir = filePath(user: user, repo: repo, type: type, name: name, version: version, filename: "x")
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: versionDir)
        env.packages.remove(at: idx)
        try persist(env, user: user, repo: repo)
    }

    @discardableResult
    func putFile(
        user: String, repo: String,
        type: String, name: String, version: String,
        filename: String, body: Data, contentType: String?,
        by author: String
    ) throws -> File {
        try Self.validateSegment(filename, fieldName: "filename")
        guard !body.isEmpty else { throw StoreError.invalidInput("empty file body") }
        guard body.count <= pkgFileMaxBytes else {
            throw StoreError.invalidInput("file > \(pkgFileMaxBytes) bytes")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.packages.firstIndex(where: { $0.type == type && $0.name == name && $0.version == version }) else {
            throw StoreError.versionNotFound(type: type, name: name, version: version)
        }
        let url = filePath(user: user, repo: repo, type: type, name: name, version: version, filename: filename)
        let parent = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw StoreError.ioFailed("mkdir: \(error)") }
        // temp+move triple (FileManager.replaceItemAt fatalErrors on swift-corelibs-foundation/Windows).
        let tmp = parent.appendingPathComponent(filename + ".tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try body.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.ioFailed("write: \(error)")
        }
        let f = File(
            filename: filename, size: body.count,
            contentType: contentType ?? "application/octet-stream",
            uploadedAt: Date(), uploadedBy: author
        )
        if let existing = env.packages[idx].files.firstIndex(where: { $0.filename == filename }) {
            env.packages[idx].files[existing] = f
        } else {
            env.packages[idx].files.append(f)
        }
        env.packages[idx].updatedAt = Date()
        try persist(env, user: user, repo: repo)
        return f
    }

    func deleteFile(user: String, repo: String, type: String, name: String, version: String, filename: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.packages.firstIndex(where: { $0.type == type && $0.name == name && $0.version == version }) else {
            throw StoreError.versionNotFound(type: type, name: name, version: version)
        }
        guard let fidx = env.packages[idx].files.firstIndex(where: { $0.filename == filename }) else {
            throw StoreError.fileNotFound(filename: filename)
        }
        let url = filePath(user: user, repo: repo, type: type, name: name, version: version, filename: filename)
        try? FileManager.default.removeItem(at: url)
        env.packages[idx].files.remove(at: fidx)
        env.packages[idx].updatedAt = Date()
        try persist(env, user: user, repo: repo)
    }

    func readFileBytes(user: String, repo: String, type: String, name: String, version: String, filename: String) throws -> (File, Data) {
        let v = try get(user: user, repo: repo, type: type, name: name, version: version)
        guard let f = v.files.first(where: { $0.filename == filename }) else {
            throw StoreError.fileNotFound(filename: filename)
        }
        let url = filePath(user: user, repo: repo, type: type, name: name, version: version, filename: filename)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw StoreError.ioFailed("read \(url.path): \(error)") }
        return (f, data)
    }
}

// MARK: - Routes

func registerPackageRoutes(
    _ app: Application,
    store: PackageStore,
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
        guard let pushAuth else { throw Abort(.serviceUnavailable, reason: "package writes disabled (no push auth)") }
        if let challenge = try await pushAuth.gate(req) {
            var headers = HTTPHeaders()
            if let h = challenge.headers.first(name: .wwwAuthenticate) {
                headers.add(name: .wwwAuthenticate, value: h)
            }
            throw Abort(.unauthorized, headers: headers, reason: "authentication required for package writes")
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
                    scope: "publishing packages"
                )
            } catch let e as AccessController.AccessError {
                throw Abort(e.status, headers: e.headers, reason: e.reason)
            }
        }
        return name
    }
    @Sendable
    func gateAdmin(_ req: Request, user: String, repo: String) async throws -> String {
        let name = try await gateWrite(req, user: user, repo: repo)
        if let access {
            do {
                try await access.require(
                    AuthIdentity(name: name, isGlobalAdmin: false),
                    atLeast: .admin,
                    user: user, repo: repo,
                    scope: "deleting packages"
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

    app.get("api", "repos", ":user", ":repo", "packages") { req async throws -> Response in
        let (u, r) = try params(req)
        try await gateRead(req, user: u, repo: r)
        let pkgs = try await store.list(user: u, repo: r)
        let res = Response(status: .ok)
        try res.content.encode(PackageListDTO(user: u, repo: r, count: pkgs.count, packages: pkgs), as: .json)
        return res
    }
    app.get("api", "repos", ":user", ":repo", "packages", ":type") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type") else { throw Abort(.badRequest, reason: "missing :type") }
        try await gateRead(req, user: u, repo: r)
        let pkgs = try await store.list(user: u, repo: r, type: type)
        let res = Response(status: .ok)
        try res.content.encode(PackageListDTO(user: u, repo: r, count: pkgs.count, packages: pkgs), as: .json)
        return res
    }
    app.get("api", "repos", ":user", ":repo", "packages", ":type", ":name") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name")
        else { throw Abort(.badRequest, reason: "missing :type or :name") }
        try await gateRead(req, user: u, repo: r)
        let pkgs = try await store.list(user: u, repo: r, type: type, name: name)
        let res = Response(status: .ok)
        try res.content.encode(PackageListDTO(user: u, repo: r, count: pkgs.count, packages: pkgs), as: .json)
        return res
    }
    app.get("api", "repos", ":user", ":repo", "packages", ":type", ":name", ":version") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name"),
              let version = req.parameters.get("version")
        else { throw Abort(.badRequest, reason: "missing :type, :name or :version") }
        try await gateRead(req, user: u, repo: r)
        do {
            let v = try await store.get(user: u, repo: r, type: type, name: name, version: version)
            let res = Response(status: .ok)
            try res.content.encode(v, as: .json)
            return res
        } catch let e as PackageStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }
    app.get("api", "repos", ":user", ":repo", "packages", ":type", ":name", ":version", "files", ":file") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name"),
              let version = req.parameters.get("version"),
              let file = req.parameters.get("file")
        else { throw Abort(.badRequest, reason: "missing path parameters") }
        try await gateRead(req, user: u, repo: r)
        let result: (PackageStore.File, Data)
        do {
            result = try await store.readFileBytes(user: u, repo: r, type: type, name: name, version: version, filename: file)
        } catch let e as PackageStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
        let (f, data) = result
        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: f.contentType)
        res.headers.replaceOrAdd(name: .contentDisposition,
                                 value: "attachment; filename=\"\(f.filename)\"")
        res.body = .init(data: data)
        return res
    }

    app.post("api", "repos", ":user", ":repo", "packages", ":type", ":name", ":version") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name"),
              let version = req.parameters.get("version")
        else { throw Abort(.badRequest, reason: "missing :type, :name or :version") }
        let author = try await gateWrite(req, user: u, repo: r)
        let dto = try req.content.decode(CreatePackageDTO.self)
        do {
            let v = try await store.create(
                user: u, repo: r,
                type: type, name: name, version: version,
                description: dto.description, manifest: dto.manifest,
                by: author
            )
            let res = Response(status: .created)
            try res.content.encode(v, as: .json)
            return res
        } catch let e as PackageStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "repos", ":user", ":repo", "packages", ":type", ":name", ":version") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name"),
              let version = req.parameters.get("version")
        else { throw Abort(.badRequest, reason: "missing :type, :name or :version") }
        _ = try await gateAdmin(req, user: u, repo: r)
        do { try await store.delete(user: u, repo: r, type: type, name: name, version: version) }
        catch let e as PackageStore.StoreError { throw Abort(e.status, reason: e.reason) }
        return Response(status: .noContent)
    }

    // File PUT (raw body up to 256 MiB).
    app.on(.PUT, "api", "repos", ":user", ":repo", "packages", ":type", ":name", ":version", "files", ":file",
           body: .collect(maxSize: ByteCount(value: 256 * 1024 * 1024)))
    { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name"),
              let version = req.parameters.get("version"),
              let file = req.parameters.get("file")
        else { throw Abort(.badRequest, reason: "missing path parameters") }
        let author = try await gateWrite(req, user: u, repo: r)
        let bodyBytes: Data
        if let buffer = req.body.data {
            bodyBytes = Data(buffer: buffer)
        } else {
            bodyBytes = Data()
        }
        let ct = req.headers.first(name: .contentType)
        do {
            let f = try await store.putFile(
                user: u, repo: r,
                type: type, name: name, version: version,
                filename: file, body: bodyBytes, contentType: ct, by: author
            )
            let res = Response(status: .created)
            try res.content.encode(f, as: .json)
            return res
        } catch let e as PackageStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "repos", ":user", ":repo", "packages", ":type", ":name", ":version", "files", ":file") { req async throws -> Response in
        let (u, r) = try params(req)
        guard let type = req.parameters.get("type"),
              let name = req.parameters.get("name"),
              let version = req.parameters.get("version"),
              let file = req.parameters.get("file")
        else { throw Abort(.badRequest, reason: "missing path parameters") }
        _ = try await gateWrite(req, user: u, repo: r)
        do { try await store.deleteFile(user: u, repo: r, type: type, name: name, version: version, filename: file) }
        catch let e as PackageStore.StoreError { throw Abort(e.status, reason: e.reason) }
        return Response(status: .noContent)
    }
}

private struct CreatePackageDTO: Content {
    let description: String?
    let manifest: String?
}

private struct PackageListDTO: Content {
    let user: String
    let repo: String
    let count: Int
    let packages: [PackageStore.Version]
}
