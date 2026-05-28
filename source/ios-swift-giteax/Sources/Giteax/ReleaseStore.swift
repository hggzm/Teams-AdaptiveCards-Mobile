import Foundation
import Vapor

/// Filesystem-backed release tracker (Phase 13).
///
/// On-disk shape (sibling of issues.json / prs.json / webhooks.json):
///
///     <root>/.giteax/repos/<user>/<repo>/releases.json
///       { version, releases: [Release] }
///     <root>/.giteax/repos/<user>/<repo>/releases/<tag>/<filename>
///       (binary asset files, one per release)
///
/// A release in v0.0.12 is a small piece of metadata layered on top of
/// an existing git tag. The tag itself must already exist in the repo
/// (created via `git push --tags` or by an admin elsewhere) -- this
/// store doesn't synthesize tags. Each release tracks:
///   - tag (must match a real ref in the repo at create time)
///   - name (human title, defaults to the tag)
///   - body (markdown changelog)
///   - draft / prerelease flags
///   - authorName, createdAt, updatedAt
///   - asset filenames + sizes (the actual bytes live next door in
///     `releases/<tag>/<filename>`)
///
/// All mutations require admin on the repo (release publishing is an
/// administrative action; the existing access controller does the
/// per-request enforcement at the route layer).
actor ReleaseStore {

    struct Release: Sendable, Codable {
        let tag: String
        var name: String
        var body: String
        var draft: Bool
        var prerelease: Bool
        let authorName: String
        let createdAt: Date
        var updatedAt: Date
        var assets: [Asset]
    }

    struct Asset: Sendable, Codable {
        /// Stored filename (sanitised; no slashes).
        let filename: String
        let size: Int
        let contentType: String
        let uploadedAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var releases: [Release]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case tagNotFound(String)
        case releaseNotFound(tag: String)
        case alreadyExists(tag: String)
        case assetNotFound(tag: String, filename: String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound, .tagNotFound, .releaseNotFound, .assetNotFound: .notFound
            case .alreadyExists: .conflict
            case .invalidInput: .badRequest
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): "no repository at \(u)/\(r)"
            case .tagNotFound(let t):         "tag '\(t)' not found in repo"
            case .releaseNotFound(let t):     "no release for tag '\(t)'"
            case .alreadyExists(let t):       "release for tag '\(t)' already exists"
            case .assetNotFound(let t, let f): "release '\(t)' has no asset '\(f)'"
            case .invalidInput(let d):        "invalid release input: \(d)"
            case .ioFailed(let d):            "release-store I/O failed: \(d)"
            case .badEnvelope(let d):         "release-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    let repoService: RepositoryService

    private var envelopes: [String: Envelope] = [:]

    init(root: URL, repoService: RepositoryService) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.root = root
        self.repoService = repoService
    }

    /// Phase 44: drop cached envelope for `user/repo`.
    func evictRepo(user: String, repo: String) {
        envelopes.removeValue(forKey: "\(user)/\(repo)")
    }

    // MARK: - Read

    func list(user: String, repo: String) throws -> [Release] {
        var env = try loadOrInit(user: user, repo: repo)
        env.releases.sort { $0.createdAt > $1.createdAt }
        return env.releases
    }

    func get(user: String, repo: String, tag: String) throws -> Release {
        let env = try loadOrInit(user: user, repo: repo)
        guard let r = env.releases.first(where: { $0.tag == tag }) else {
            throw StoreError.releaseNotFound(tag: tag)
        }
        return r
    }

    /// Read a single asset's bytes for download.
    func readAsset(user: String, repo: String, tag: String, filename: String) throws -> (Asset, Data) {
        let release = try get(user: user, repo: repo, tag: tag)
        guard let asset = release.assets.first(where: { $0.filename == filename }) else {
            throw StoreError.assetNotFound(tag: tag, filename: filename)
        }
        let url = assetURL(user: user, repo: repo, tag: tag, filename: filename)
        do {
            let data = try Data(contentsOf: url)
            return (asset, data)
        } catch {
            throw StoreError.ioFailed("read asset \(filename): \(error)")
        }
    }

    // MARK: - Mutate

    @discardableResult
    func create(
        user: String, repo: String,
        tag: String,
        name: String?,
        body: String,
        draft: Bool,
        prerelease: Bool,
        authorName: String
    ) throws -> Release {
        // Tag must exist in the repo.
        try validateTagExists(user: user, repo: repo, tag: tag)
        var env = try loadOrInit(user: user, repo: repo)
        guard !env.releases.contains(where: { $0.tag == tag }) else {
            throw StoreError.alreadyExists(tag: tag)
        }
        let now = Date()
        let release = Release(
            tag: tag,
            name: (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            body: body,
            draft: draft,
            prerelease: prerelease,
            authorName: authorName,
            createdAt: now,
            updatedAt: now,
            assets: []
        )
        env.releases.append(release)
        try persist(env, user: user, repo: repo)
        return release
    }

    @discardableResult
    func update(
        user: String, repo: String, tag: String,
        name: String? = nil,
        body: String? = nil,
        draft: Bool? = nil,
        prerelease: Bool? = nil
    ) throws -> Release {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.releases.firstIndex(where: { $0.tag == tag }) else {
            throw StoreError.releaseNotFound(tag: tag)
        }
        var r = env.releases[idx]
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { r.name = t }
        }
        if let body { r.body = body }
        if let draft { r.draft = draft }
        if let prerelease { r.prerelease = prerelease }
        r.updatedAt = Date()
        env.releases[idx] = r
        try persist(env, user: user, repo: repo)
        return r
    }

    func delete(user: String, repo: String, tag: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.releases.contains(where: { $0.tag == tag }) else {
            throw StoreError.releaseNotFound(tag: tag)
        }
        env.releases.removeAll { $0.tag == tag }
        try persist(env, user: user, repo: repo)
        // Best-effort: also remove the asset directory for this tag.
        let dir = assetDir(user: user, repo: repo, tag: tag)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Persist asset bytes + record metadata. Overwrites if a same-named
    /// asset already exists on the release.
    @discardableResult
    func upsertAsset(
        user: String, repo: String, tag: String,
        filename: String, contentType: String, data: Data
    ) throws -> Asset {
        let cleanName = Self.sanitiseFilename(filename)
        guard !cleanName.isEmpty else {
            throw StoreError.invalidInput("filename is empty or invalid")
        }
        guard data.count <= 256 * 1024 * 1024 else {
            throw StoreError.invalidInput("asset too large (256 MiB max)")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.releases.firstIndex(where: { $0.tag == tag }) else {
            throw StoreError.releaseNotFound(tag: tag)
        }
        // Persist to disk first; only update the index if the write succeeds.
        let dir = assetDir(user: user, repo: repo, tag: tag)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.ioFailed("mkdir release dir: \(error)")
        }
        let url = dir.appendingPathComponent(cleanName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.ioFailed("write asset: \(error)")
        }
        let asset = Asset(
            filename: cleanName,
            size: data.count,
            contentType: contentType,
            uploadedAt: Date()
        )
        var rel = env.releases[idx]
        rel.assets.removeAll { $0.filename == cleanName }
        rel.assets.append(asset)
        rel.updatedAt = Date()
        env.releases[idx] = rel
        try persist(env, user: user, repo: repo)
        return asset
    }

    func deleteAsset(user: String, repo: String, tag: String, filename: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.releases.firstIndex(where: { $0.tag == tag }) else {
            throw StoreError.releaseNotFound(tag: tag)
        }
        var rel = env.releases[idx]
        guard rel.assets.contains(where: { $0.filename == filename }) else {
            throw StoreError.assetNotFound(tag: tag, filename: filename)
        }
        rel.assets.removeAll { $0.filename == filename }
        rel.updatedAt = Date()
        env.releases[idx] = rel
        try persist(env, user: user, repo: repo)
        let url = assetURL(user: user, repo: repo, tag: tag, filename: filename)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    /// Refuse to create a release for a tag that doesn't exist in the
    /// underlying git repo. Uses SwiftGitX's tag collection.
    private func validateTagExists(user: String, repo: String, tag: String) throws {
        do {
            let r = try repoService.open(user: user, repo: repo)
            _ = try r.tag.get(named: tag)
        } catch let e as RepositoryService.LookupError {
            if case .notFound = e {
                throw StoreError.repoNotFound(user: user, repo: repo)
            }
            throw StoreError.repoNotFound(user: user, repo: repo)
        } catch {
            // Anything thrown by SwiftGitX's tag.get(named:) -- usually
            // "no such tag" -- maps to tagNotFound here.
            throw StoreError.tagNotFound(tag)
        }
    }

    /// Strip path-separator characters and anything non-printable. We
    /// keep dots / dashes / underscores so common artifact names survive
    /// (`build-1.0.0.zip`, `release_notes.md`, etc.).
    static func sanitiseFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject anything that obviously tries to escape:
        if trimmed.contains("/") || trimmed.contains("\\")
            || trimmed.contains("..") || trimmed.isEmpty
            || trimmed.count > 255 {
            return ""
        }
        // Keep only printable ASCII + UTF-8 letters/digits/. _-.
        let allowed: Set<Character> = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+"
        )
        let filtered = trimmed.filter { allowed.contains($0) }
        return filtered == trimmed ? trimmed : ""
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let key = "\(user)/\(repo)"
        if let cached = envelopes[key] { return cached }
        if !repoExistsOnDisk(user: user, repo: repo) {
            throw StoreError.repoNotFound(user: user, repo: repo)
        }
        let url = envelopeURL(user: user, repo: repo)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let env = try dec.decode(Envelope.self, from: data)
                envelopes[key] = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(version: 1, releases: [])
        envelopes[key] = env
        return env
    }

    private func repoExistsOnDisk(user: String, repo: String) -> Bool {
        let bare = root.appendingPathComponent(user)
            .appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("releases.json")
    }

    private func assetDir(user: String, repo: String, tag: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent(tag, isDirectory: true)
    }

    private func assetURL(user: String, repo: String, tag: String, filename: String) -> URL {
        assetDir(user: user, repo: repo, tag: tag).appendingPathComponent(filename)
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        envelopes[key] = env
        let url = envelopeURL(user: user, repo: repo)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.ioFailed("mkdir: \(error)")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try enc.encode(env)
        } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        // Same atomic-ish dance as the other stores.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("releases.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
