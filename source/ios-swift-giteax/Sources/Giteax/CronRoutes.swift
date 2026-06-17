import Foundation
import Vapor
import AsyncHTTPClient
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// Phase 48 -- global scheduled-jobs registry ("cron").
///
/// On-disk shape (`<root>/.giteax/cron.json`):
///
///     {
///       "version": 1,
///       "jobs": [
///         {
///           "name": "nightly-cleanup",
///           "intervalSeconds": 86400,
///           "targetURL": "http://127.0.0.1:9000/hooks/cleanup",
///           "method": "POST",
///           "body": "{\"task\":\"cleanup\"}",
///           "headerName": "X-Giteax-Cron",
///           "headerValue": "nightly-cleanup",
///           "active": true,
///           "createdAt": "...",
///           "lastRunAt": "...",
///           "lastStatus": 200,
///           "lastResponseExcerpt": "...",
///           "runCount": 17
///         }
///       ]
///     }
///
/// Job is invoked by the background ticker every time
/// `now - lastRunAt >= intervalSeconds` (or `now - createdAt` if never
/// run). Fires are HTTP requests via `URLSession.shared.data(for:)`;
/// timeouts are 15 s. Failures don't unschedule; the next tick re-tries.
actor CronStore {

    struct Job: Sendable, Codable {
        let name: String
        var intervalSeconds: Int
        var targetURL: String
        var method: String              // "POST" or "GET"
        var body: String                // ignored if method == GET
        var headerName: String?
        var headerValue: String?
        var active: Bool
        let createdAt: Date
        var lastRunAt: Date?
        var lastStatus: Int?
        var lastResponseExcerpt: String?
        var runCount: Int
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var jobs: [Job]
    }

    enum StoreError: Error, CustomStringConvertible {
        case ioFailed(String)
        case badEnvelope(String)
        case notFound(String)
        case alreadyExists(String)
        case invalidInput(String)

        var description: String {
            switch self {
            case .ioFailed(let s):       "cron I/O: \(s)"
            case .badEnvelope(let s):    "cron envelope: \(s)"
            case .notFound(let s):       "no such cron job: '\(s)'"
            case .alreadyExists(let s):  "cron job '\(s)' already exists"
            case .invalidInput(let s):   "invalid input: \(s)"
            }
        }
    }

    static let minIntervalSeconds = 1          // tests need fast intervals
    static let maxIntervalSeconds = 86400      // one day
    static let bodyMaxBytes = 64 * 1024
    static let responseExcerptMax = 512

    let storePath: URL
    private var envelope: Envelope

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storePath = dir.appendingPathComponent("cron.json")
        if FileManager.default.fileExists(atPath: storePath.path) {
            do {
                let data = try Data(contentsOf: storePath)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                self.envelope = try dec.decode(Envelope.self, from: data)
            } catch {
                throw StoreError.badEnvelope("\(error)")
            }
        } else {
            self.envelope = Envelope(version: 1, jobs: [])
            try Self.persist(envelope, to: storePath)
        }
    }

    // MARK: - Read

    func list() -> [Job] { envelope.jobs.sorted { $0.name < $1.name } }

    func get(_ name: String) -> Job? {
        envelope.jobs.first(where: { $0.name == name })
    }

    // MARK: - Mutate

    @discardableResult
    func create(
        name: String,
        intervalSeconds: Int,
        targetURL: String,
        method: String,
        body: String,
        headerName: String?,
        headerValue: String?
    ) throws -> Job {
        guard RepositoryService.validateSegment(name) else {
            throw StoreError.invalidInput("name must match [A-Za-z0-9][A-Za-z0-9._-]*")
        }
        guard envelope.jobs.first(where: { $0.name == name }) == nil else {
            throw StoreError.alreadyExists(name)
        }
        guard intervalSeconds >= Self.minIntervalSeconds, intervalSeconds <= Self.maxIntervalSeconds else {
            throw StoreError.invalidInput("intervalSeconds must be in [\(Self.minIntervalSeconds), \(Self.maxIntervalSeconds)]")
        }
        guard let url = URL(string: targetURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw StoreError.invalidInput("targetURL must be http:// or https://")
        }
        let m = method.uppercased()
        guard m == "POST" || m == "GET" else {
            throw StoreError.invalidInput("method must be POST or GET")
        }
        if body.utf8.count > Self.bodyMaxBytes {
            throw StoreError.invalidInput("body exceeds \(Self.bodyMaxBytes) bytes")
        }
        if let h = headerName, !h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            throw StoreError.invalidInput("headerName has invalid characters")
        }
        let job = Job(
            name: name,
            intervalSeconds: intervalSeconds,
            targetURL: targetURL,
            method: m,
            body: body,
            headerName: headerName,
            headerValue: headerValue,
            active: true,
            createdAt: Date(),
            lastRunAt: nil,
            lastStatus: nil,
            lastResponseExcerpt: nil,
            runCount: 0
        )
        envelope.jobs.append(job)
        try Self.persist(envelope, to: storePath)
        return job
    }

    @discardableResult
    func setActive(_ name: String, _ active: Bool) throws -> Job {
        guard let idx = envelope.jobs.firstIndex(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        envelope.jobs[idx].active = active
        try Self.persist(envelope, to: storePath)
        return envelope.jobs[idx]
    }

    func delete(_ name: String) throws {
        guard let idx = envelope.jobs.firstIndex(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        envelope.jobs.remove(at: idx)
        try Self.persist(envelope, to: storePath)
    }

    /// Mark a fire result. Used by the ticker after each invocation,
    /// and by the manual `run` endpoint for diagnostics.
    func recordFire(name: String, at when: Date, status: Int?, responseExcerpt: String?) {
        guard let idx = envelope.jobs.firstIndex(where: { $0.name == name }) else { return }
        envelope.jobs[idx].lastRunAt = when
        envelope.jobs[idx].lastStatus = status
        envelope.jobs[idx].lastResponseExcerpt = responseExcerpt
        envelope.jobs[idx].runCount += 1
        try? Self.persist(envelope, to: storePath)
    }

    /// Returns the set of active jobs whose interval has elapsed since
    /// their last run (or since createdAt if never run).
    func dueJobs(now: Date) -> [Job] {
        envelope.jobs.filter { j in
            guard j.active else { return false }
            let lastTime = j.lastRunAt ?? j.createdAt
            return now.timeIntervalSince(lastTime) >= Double(j.intervalSeconds)
        }
    }

    private static func persist(_ env: Envelope, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) } catch { throw StoreError.ioFailed("encode: \(error)") }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("cron.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

/// Background ticker that fires due jobs once per second. Started by
/// the Vapor app at boot and torn down on shutdown.
actor CronTicker {
    private let store: CronStore
    private var task: Task<Void, Never>?
    private let logger: Logger

    init(store: CronStore, logger: Logger) {
        self.store = store
        self.logger = logger
    }

    func start() {
        if task != nil { return }
        task = Task { [store, logger] in
            while !Task.isCancelled {
                let now = Date()
                let due = await store.dueJobs(now: now)
                for job in due {
                    let (status, excerpt) = await CronTicker.fire(job: job, logger: logger)
                    await store.recordFire(name: job.name, at: Date(), status: status, responseExcerpt: excerpt)
                }
                // Sleep ~1 s but exit quickly on cancellation.
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Fire one job. Returns the HTTP status (or nil on transport error)
    /// and a UTF-8 excerpt of the response body (truncated).
    static func fire(job: CronStore.Job, logger: Logger) async -> (Int?, String?) {
        do {
            var req = HTTPClientRequest(url: job.targetURL)
            req.method = (job.method == "GET") ? .GET : .POST
            if job.method == "POST" {
                req.headers.add(name: "Content-Type", value: "application/json")
                req.body = .bytes(ByteBuffer(string: job.body))
            }
            if let h = job.headerName, let v = job.headerValue, !h.isEmpty {
                req.headers.add(name: h, value: v)
            }
            let resp = try await HTTPClient.shared.execute(req, timeout: .seconds(15))
            let status = Int(resp.status.code)
            let buf = try await resp.body.collect(upTo: 64 * 1024)
            let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
            let excerpt = String(s.prefix(CronStore.responseExcerptMax))
            return (status, excerpt)
        } catch {
            logger.warning("[giteax/cron] '\(job.name)' fire failed: \(error)")
            return (nil, "transport error: \(error)")
        }
    }
}

// MARK: - Routes

/// Phase 48 -- cron HTTP endpoints (all admin-token gated).
///
///   GET    /api/cron                       list jobs
///   POST   /api/cron                       create job (body: CronCreateDTO)
///   GET    /api/cron/:name                 fetch job
///   DELETE /api/cron/:name                 remove job
///   POST   /api/cron/:name/pause           set active=false
///   POST   /api/cron/:name/resume          set active=true
///   POST   /api/cron/:name/run             fire now once (for diagnostics)
func registerCronRoutes(
    _ app: Application,
    store: CronStore,
    adminToken: String?,
    logger: Logger
) {
    struct AdminBearer: AsyncMiddleware {
        let expected: String
        func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            guard let raw = req.headers.bearerAuthorization?.token, raw == expected else {
                throw Abort(.unauthorized, reason: "admin token required")
            }
            return try await next.respond(to: req)
        }
    }
    let admin = app.grouped(AdminBearer(expected: adminToken ?? ""))

    admin.get("api", "cron") { req async throws -> Response in
        let jobs = await store.list()
        let dto = CronListDTO(count: jobs.count, jobs: jobs.map(CronJobDTO.from))
        let resp = Response(status: .ok)
        try resp.content.encode(dto, as: .json)
        return resp
    }

    admin.post("api", "cron") { req async throws -> Response in
        let body = try req.content.decode(CronCreateDTO.self)
        do {
            let job = try await store.create(
                name: body.name,
                intervalSeconds: body.intervalSeconds,
                targetURL: body.targetURL,
                method: body.method ?? "POST",
                body: body.body ?? "",
                headerName: body.headerName,
                headerValue: body.headerValue
            )
            let resp = Response(status: .created)
            try resp.content.encode(CronJobDTO.from(job), as: .json)
            return resp
        } catch let e as CronStore.StoreError {
            switch e {
            case .invalidInput(let m):     throw Abort(.badRequest, reason: m)
            case .alreadyExists(let n):    throw Abort(.conflict, reason: "cron '\(n)' already exists")
            default:                       throw Abort(.internalServerError, reason: e.description)
            }
        }
    }

    admin.get("api", "cron", ":name") { req async throws -> Response in
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        guard let j = await store.get(n) else { throw Abort(.notFound, reason: "no such cron '\(n)'") }
        let resp = Response(status: .ok)
        try resp.content.encode(CronJobDTO.from(j), as: .json)
        return resp
    }

    admin.delete("api", "cron", ":name") { req async throws -> Response in
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        do {
            try await store.delete(n)
            return Response(status: .noContent)
        } catch CronStore.StoreError.notFound(let s) {
            throw Abort(.notFound, reason: "no such cron '\(s)'")
        }
    }

    admin.post("api", "cron", ":name", "pause") { req async throws -> Response in
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        do {
            let j = try await store.setActive(n, false)
            let resp = Response(status: .ok)
            try resp.content.encode(CronJobDTO.from(j), as: .json)
            return resp
        } catch CronStore.StoreError.notFound(let s) {
            throw Abort(.notFound, reason: "no such cron '\(s)'")
        }
    }

    admin.post("api", "cron", ":name", "resume") { req async throws -> Response in
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        do {
            let j = try await store.setActive(n, true)
            let resp = Response(status: .ok)
            try resp.content.encode(CronJobDTO.from(j), as: .json)
            return resp
        } catch CronStore.StoreError.notFound(let s) {
            throw Abort(.notFound, reason: "no such cron '\(s)'")
        }
    }

    admin.post("api", "cron", ":name", "run") { req async throws -> Response in
        guard let n = req.parameters.get("name") else { throw Abort(.badRequest, reason: "missing :name") }
        guard let j = await store.get(n) else { throw Abort(.notFound, reason: "no such cron '\(n)'") }
        let (status, excerpt) = await CronTicker.fire(job: j, logger: logger)
        await store.recordFire(name: j.name, at: Date(), status: status, responseExcerpt: excerpt)
        let updated = await store.get(n)!
        let resp = Response(status: .ok)
        try resp.content.encode(CronJobDTO.from(updated), as: .json)
        return resp
    }
}

// MARK: - DTOs

private struct CronCreateDTO: Content {
    let name: String
    let intervalSeconds: Int
    let targetURL: String
    let method: String?
    let body: String?
    let headerName: String?
    let headerValue: String?
}

private struct CronJobDTO: Content {
    let name: String
    let intervalSeconds: Int
    let targetURL: String
    let method: String
    let body: String
    let headerName: String?
    let headerValue: String?
    let active: Bool
    let createdAt: Date
    let lastRunAt: Date?
    let lastStatus: Int?
    let lastResponseExcerpt: String?
    let runCount: Int

    static func from(_ j: CronStore.Job) -> CronJobDTO {
        .init(
            name: j.name, intervalSeconds: j.intervalSeconds,
            targetURL: j.targetURL, method: j.method, body: j.body,
            headerName: j.headerName, headerValue: j.headerValue,
            active: j.active, createdAt: j.createdAt,
            lastRunAt: j.lastRunAt, lastStatus: j.lastStatus,
            lastResponseExcerpt: j.lastResponseExcerpt,
            runCount: j.runCount
        )
    }
}

private struct CronListDTO: Content {
    let count: Int
    let jobs: [CronJobDTO]
}
