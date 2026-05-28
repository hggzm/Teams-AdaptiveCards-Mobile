import Foundation
import Vapor

/// Phase 49 -- per-repo upstream mirroring.
///
/// On-disk shape (per repo, alongside the other envelopes):
///
///     <root>/.giteax/repos/<user>/<repo>/mirror.json
///     {
///       "version": 1,
///       "config": {
///         "enabled": true,
///         "upstreamURL": "https://github.com/example/upstream.git",
///         "intervalSeconds": 3600,
///         "createdAt": "...", "createdBy": "hggz",
///         "lastSyncAt": "...", "lastStatus": "ok"|"error"|"never",
///         "lastError": "...?",
///         "syncCount": 17
///       }
///     }
///
/// Sync algorithm (admin-only or write-ACL holder):
///   1. Ensure bare repo at <root>/<user>/<repo>.git exists.
///   2. `git --git-dir=<bare> remote remove _giteax_mirror` (best-effort)
///   3. `git --git-dir=<bare> remote add _giteax_mirror <upstreamURL>`
///   4. `git --git-dir=<bare> fetch --prune --tags _giteax_mirror`
///      with refspec `+refs/heads/*:refs/heads/*`
///   5. Record outcome.
///
/// Sync surface is intentionally one-way (no push back). Mirroring is
/// also force-update — local divergent refs are overwritten, matching
/// Gitea's mirror semantics.
actor MirrorStore {

    struct Config: Sendable, Codable {
        var enabled: Bool
        var upstreamURL: String
        var intervalSeconds: Int
        let createdAt: Date
        let createdBy: String
        var lastSyncAt: Date?
        var lastStatus: String      // "never" | "ok" | "error"
        var lastError: String?
        var syncCount: Int
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var config: Config?
    }

    enum StoreError: Error, CustomStringConvertible {
        case ioFailed(String)
        case badEnvelope(String)
        case invalidInput(String)
        case notFound

        var description: String {
            switch self {
            case .ioFailed(let s):       "mirror I/O: \(s)"
            case .badEnvelope(let s):    "mirror envelope: \(s)"
            case .invalidInput(let s):   "invalid input: \(s)"
            case .notFound:              "mirror not configured"
            }
        }
    }

    static let minIntervalSeconds = 30
    static let maxIntervalSeconds = 86400 * 7      // one week
    static let urlMaxLen = 1024

    let root: URL

    init(root: URL) { self.root = root }

    private func dirURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }
    private func envelopeURL(user: String, repo: String) -> URL {
        dirURL(user: user, repo: repo).appendingPathComponent("mirror.json")
    }

    private func loadOrEmpty(user: String, repo: String) throws -> Envelope {
        let url = envelopeURL(user: user, repo: repo)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Envelope(version: 1, config: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(Envelope.self, from: data)
        } catch {
            throw StoreError.badEnvelope("\(error)")
        }
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        try FileManager.default.createDirectory(
            at: dirURL(user: user, repo: repo), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) } catch { throw StoreError.ioFailed("encode: \(error)") }
        let url = envelopeURL(user: user, repo: repo)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("mirror.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

    // MARK: - Read

    func get(user: String, repo: String) throws -> Config? {
        try loadOrEmpty(user: user, repo: repo).config
    }

    // Returns repos with active mirror configs whose interval has elapsed.
    func dueMirrors(now: Date) -> [(user: String, repo: String, config: Config)] {
        // We can't efficiently enumerate without walking the repos dir.
        // Mirror state lives under .giteax/repos/<u>/<r>/mirror.json.
        let base = root.appendingPathComponent(".giteax").appendingPathComponent("repos")
        guard let userDirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(String, String, Config)] = []
        for u in userDirs {
            guard let repoDirs = try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) else { continue }
            for r in repoDirs {
                let envFile = r.appendingPathComponent("mirror.json")
                guard FileManager.default.fileExists(atPath: envFile.path) else { continue }
                guard let data = try? Data(contentsOf: envFile) else { continue }
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                guard let env = try? dec.decode(Envelope.self, from: data),
                      let cfg = env.config, cfg.enabled else { continue }
                let last = cfg.lastSyncAt ?? cfg.createdAt
                if now.timeIntervalSince(last) >= Double(cfg.intervalSeconds) {
                    out.append((u.lastPathComponent, r.lastPathComponent, cfg))
                }
            }
        }
        return out
    }

    // MARK: - Mutate

    @discardableResult
    func upsert(
        user: String, repo: String,
        upstreamURL: String, intervalSeconds: Int,
        enabled: Bool, actor actorName: String
    ) throws -> Config {
        guard let u = URL(string: upstreamURL),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            throw StoreError.invalidInput("upstreamURL must be http://, https://, or file://")
        }
        guard upstreamURL.count <= Self.urlMaxLen else {
            throw StoreError.invalidInput("upstreamURL exceeds \(Self.urlMaxLen) bytes")
        }
        guard intervalSeconds >= Self.minIntervalSeconds, intervalSeconds <= Self.maxIntervalSeconds else {
            throw StoreError.invalidInput("intervalSeconds must be in [\(Self.minIntervalSeconds), \(Self.maxIntervalSeconds)]")
        }
        var env = try loadOrEmpty(user: user, repo: repo)
        if var existing = env.config {
            existing.upstreamURL = upstreamURL
            existing.intervalSeconds = intervalSeconds
            existing.enabled = enabled
            env.config = existing
        } else {
            env.config = Config(
                enabled: enabled,
                upstreamURL: upstreamURL,
                intervalSeconds: intervalSeconds,
                createdAt: Date(),
                createdBy: actorName,
                lastSyncAt: nil,
                lastStatus: "never",
                lastError: nil,
                syncCount: 0
            )
        }
        try persist(env, user: user, repo: repo)
        return env.config!
    }

    func delete(user: String, repo: String) throws {
        var env = try loadOrEmpty(user: user, repo: repo)
        guard env.config != nil else { throw StoreError.notFound }
        env.config = nil
        try persist(env, user: user, repo: repo)
    }

    /// Per-repo eviction stub for Phase 44 transfer/rename symmetry.
    /// No in-actor cache to clear; state is always loaded from disk.
    func evictRepo(user: String, repo: String) { /* no-op */ }

    func recordResult(user: String, repo: String, ok: Bool, error: String?) {
        guard var env = try? loadOrEmpty(user: user, repo: repo),
              var cfg = env.config else { return }
        cfg.lastSyncAt = Date()
        cfg.lastStatus = ok ? "ok" : "error"
        cfg.lastError = error
        cfg.syncCount += 1
        env.config = cfg
        try? persist(env, user: user, repo: repo)
    }
}

// MARK: - Sync executor

/// Background ticker that runs due mirrors every 10 seconds. Stays
/// out of the per-second cron ticker because git fetches are slow and
/// we don't want to flood the loop.
actor MirrorTicker {
    private let store: MirrorStore
    private let root: URL
    private let logger: Logger
    private var task: Task<Void, Never>?

    init(store: MirrorStore, root: URL, logger: Logger) {
        self.store = store
        self.root = root
        self.logger = logger
    }

    func start() {
        if task != nil { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let now = Date()
                let due = await self.store.dueMirrors(now: now)
                for (u, r, cfg) in due {
                    let (ok, err) = await self.runOnce(user: u, repo: r, config: cfg)
                    await self.store.recordResult(user: u, repo: r, ok: ok, error: err)
                    await self.logFire(user: u, repo: r, ok: ok, err: err)
                }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Runs a single sync, fully serialized inside this actor. Both
    /// the background ticker and the manual `POST /sync` route go
    /// through here so two concurrent `git remote add _giteax_mirror`
    /// invocations can never race on the same bare repo.
    func runOnce(user: String, repo: String, config cfg: MirrorStore.Config) -> (Bool, String?) {
        let bareRepo = root.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        return Self.runSync(bareRepo: bareRepo, upstreamURL: cfg.upstreamURL, logger: logger)
    }

    private func logFire(user: String, repo: String, ok: Bool, err: String?) {
        logger.info("[giteax/mirror] \(user)/\(repo) sync ok=\(ok) err=\(err ?? "-")")
    }

    /// Runs the fetch once. Returns (ok, errorMessage). Safe to call
    /// from the route handler (force-fire-now path) as well.
    static func runSync(bareRepo: URL, upstreamURL: String, logger: Logger) -> (Bool, String?) {
        guard FileManager.default.fileExists(atPath: bareRepo.path) else {
            return (false, "bare repo not found at \(bareRepo.path)")
        }
        guard let git = which("git") else {
            return (false, "git executable not in PATH")
        }
        // 1) Remove any prior _giteax_mirror remote (best-effort).
        _ = runGit(git, ["--git-dir=\(bareRepo.path)", "remote", "remove", "_giteax_mirror"])
        // 2) Add the remote pointing at upstreamURL.
        let add = runGit(git, ["--git-dir=\(bareRepo.path)", "remote", "add", "_giteax_mirror", upstreamURL])
        if add.exit != 0 {
            return (false, "remote add failed: \(add.stderr.prefix(400))")
        }
        // 3) Fetch into remote-tracking refs only (NEVER into refs/heads/* —
        //    that would let upstream's branch set silently delete or
        //    rewind local branches via `--prune`, which is catastrophic
        //    on bare repos that ARE the source of truth for hosted users).
        //    Consumers read upstream state via refs/remotes/_giteax_mirror/*.
        let fetch = runGit(git, [
            "--git-dir=\(bareRepo.path)",
            "fetch", "--tags", "_giteax_mirror",
            "+refs/heads/*:refs/remotes/_giteax_mirror/*"
        ])
        if fetch.exit != 0 {
            return (false, "fetch failed (exit \(fetch.exit)): \(fetch.stderr.prefix(400))")
        }
        return (true, nil)
    }

    private static func runGit(_ git: String, _ args: [String]) -> (exit: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
        p.waitUntilExit()
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, s)
    }
}

@Sendable
private func which(_ exe: String) -> String? {
    #if os(Windows)
    let sep: Character = ";"
    let exts = [".exe", ".cmd", ".bat", ""]
    #else
    let sep: Character = ":"
    let exts = [""]
    #endif
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    let dirs = path.split(separator: sep)
    for ext in exts {
        for dir in dirs {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(exe + ext)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
    }
    return nil
}

// MARK: - Routes

/// Phase 49 -- per-repo mirror HTTP endpoints.
///
///   GET    /api/repos/:u/:r/mirror             (read; public if repo public)
///   PUT    /api/repos/:u/:r/mirror             (write ACL) body MirrorUpsertDTO
///   DELETE /api/repos/:u/:r/mirror             (write ACL)
///   POST   /api/repos/:u/:r/mirror/sync        (write ACL) force-fire-once
func registerMirrorRoutes(
    _ app: Application,
    mirrors: MirrorStore,
    ticker: MirrorTicker,
    repos: RepositoryService,
    pushAuth: GitPushBasicAuth?,
    access: AccessController,
    logger: Logger
) {
    let root = repos.root
    _ = root  // root only used for sync (now via ticker.runOnce)

    @Sendable
    func parseUR(_ req: Request) throws -> (String, String) {
        guard let u = req.parameters.get("user"), let r = req.parameters.get("repo") else {
            throw Abort(.badRequest, reason: "missing :user/:repo")
        }
        guard RepositoryService.validateSegment(u), RepositoryService.validateSegment(r) else {
            throw Abort(.badRequest, reason: "invalid :user/:repo segment")
        }
        return (u, r)
    }

    @Sendable
    func gateRead(_ req: Request, user: String, repo: String) async throws {
        let identity = await access.identify(req)
        do {
            try await access.requireRead(identity, user: user, repo: repo, scope: "this repository")
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
    }

    @Sendable
    func gateWrite(_ req: Request, user: String, repo: String) async throws -> String {
        guard let pushAuth = pushAuth else {
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
        do {
            try await access.require(
                AuthIdentity(name: name, isGlobalAdmin: false),
                atLeast: .write, user: user, repo: repo,
                scope: "configuring mirror"
            )
        } catch let e as AccessController.AccessError {
            throw Abort(e.status, headers: e.headers, reason: e.reason)
        }
        return name
    }

    app.get("api", "repos", ":user", ":repo", "mirror") { req async throws -> Response in
        let (u, r) = try parseUR(req)
        try await gateRead(req, user: u, repo: r)
        let cfg = try await mirrors.get(user: u, repo: r)
        let resp = Response(status: .ok)
        if let cfg = cfg {
            try resp.content.encode(MirrorDTO.from(cfg), as: .json)
        } else {
            try resp.content.encode(MirrorEmptyDTO(configured: false), as: .json)
        }
        return resp
    }

    app.put("api", "repos", ":user", ":repo", "mirror") { req async throws -> Response in
        let (u, r) = try parseUR(req)
        let actorName = try await gateWrite(req, user: u, repo: r)
        let body = try req.content.decode(MirrorUpsertDTO.self)
        do {
            let cfg = try await mirrors.upsert(
                user: u, repo: r,
                upstreamURL: body.upstreamURL,
                intervalSeconds: body.intervalSeconds,
                enabled: body.enabled ?? true,
                actor: actorName
            )
            let resp = Response(status: .ok)
            try resp.content.encode(MirrorDTO.from(cfg), as: .json)
            return resp
        } catch let e as MirrorStore.StoreError {
            switch e {
            case .invalidInput(let m):   throw Abort(.badRequest, reason: m)
            default:                     throw Abort(.internalServerError, reason: e.description)
            }
        }
    }

    app.delete("api", "repos", ":user", ":repo", "mirror") { req async throws -> Response in
        let (u, r) = try parseUR(req)
        _ = try await gateWrite(req, user: u, repo: r)
        do {
            try await mirrors.delete(user: u, repo: r)
            return Response(status: .noContent)
        } catch MirrorStore.StoreError.notFound {
            throw Abort(.notFound, reason: "no mirror configured for \(u)/\(r)")
        }
    }

    app.post("api", "repos", ":user", ":repo", "mirror", "sync") { req async throws -> Response in
        let (u, r) = try parseUR(req)
        _ = try await gateWrite(req, user: u, repo: r)
        guard let cfg = try await mirrors.get(user: u, repo: r) else {
            throw Abort(.notFound, reason: "no mirror configured for \(u)/\(r)")
        }
        let (ok, err) = await ticker.runOnce(user: u, repo: r, config: cfg)
        await mirrors.recordResult(user: u, repo: r, ok: ok, error: err)
        let updated = try await mirrors.get(user: u, repo: r)!
        let resp = Response(status: ok ? .ok : .badGateway)
        try resp.content.encode(MirrorDTO.from(updated), as: .json)
        return resp
    }
}

// MARK: - DTOs

private struct MirrorUpsertDTO: Content {
    let upstreamURL: String
    let intervalSeconds: Int
    let enabled: Bool?
}

private struct MirrorDTO: Content {
    let configured: Bool
    let enabled: Bool
    let upstreamURL: String
    let intervalSeconds: Int
    let createdAt: Date
    let createdBy: String
    let lastSyncAt: Date?
    let lastStatus: String
    let lastError: String?
    let syncCount: Int

    static func from(_ c: MirrorStore.Config) -> MirrorDTO {
        .init(
            configured: true, enabled: c.enabled, upstreamURL: c.upstreamURL,
            intervalSeconds: c.intervalSeconds, createdAt: c.createdAt,
            createdBy: c.createdBy, lastSyncAt: c.lastSyncAt,
            lastStatus: c.lastStatus, lastError: c.lastError,
            syncCount: c.syncCount
        )
    }
}

private struct MirrorEmptyDTO: Content {
    let configured: Bool
}
