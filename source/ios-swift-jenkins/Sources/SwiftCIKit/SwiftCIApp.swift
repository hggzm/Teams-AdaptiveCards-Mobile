import Foundation
import Vapor

/// Configures Vapor `Application` routes and DI for the v0 controller.
///
/// v0 routes (matches HANDOFF §6 acceptance criteria):
///
/// - `GET  /`                              → product name + version
/// - `GET  /health`                        → "ok"
/// - `GET  /api/jobs`                      → JSON array of known job ids
/// - `POST /api/jobs`                      → accepts a YAML body, persists, returns `{id}`
/// - `GET  /api/jobs/:id`                  → YAML of the named job; 404 if unknown
/// - `POST /api/jobs/:id/trigger`          → queue a build, returns `{number}`
/// - `GET  /api/jobs/:id/builds`           → JSON array of build numbers (ascending)
/// - `GET  /api/jobs/:id/builds/:n`        → JSON status + last 100 log lines
/// - `POST /api/jobs/:id/builds/:n/cancel` → cancel running/queued build (409 if terminal)
/// - `POST /webhook/:id`                   → external webhook receiver (optional shared secret)
/// - `GET  /api/queue`                     → JSON snapshot of the executor's FIFO queue (Phase 22)
public enum SwiftCIApp {
    public static let productName = "Swift CI"
    public static let version = "0.1.0-alpha"

    /// Phase 26: unix-seconds timestamp captured the very first time
    /// this property is read in the lifetime of the process. Exposed
    /// on `/metrics` as `swiftci_process_start_time_seconds` so
    /// scrapers can compute uptime as `time() - that_value`. Mirrors
    /// the standard Prometheus `process_start_time_seconds` shape
    /// without pulling a full procfs collector.
    public static let processStartTimeUnixSeconds: Double = Date().timeIntervalSince1970

    /// Configure routes on `app`, using `store` to persist jobs and
    /// `executor` to run builds. The executor must already be started.
    ///
    /// If `publicDirectory` is non-nil and exists, `FileMiddleware` is
    /// installed to serve static assets from it. Files like
    /// `index.html` and `app.js` then become reachable at `/index.html`
    /// and `/app.js`; the bare `/` route still returns the product
    /// name/version banner so smoke tests like `curl /` keep working.
    ///
    /// If `webhookToken` is non-nil, `POST /webhook/:id` requires a
    /// matching token via either the `X-Webhook-Token` header or a
    /// `?token=...` query parameter. If nil, the webhook is open
    /// (anyone who can reach the port can trigger a build).
    ///
    /// If `adminToken` is non-nil, MUTATION routes (`POST /api/jobs`,
    /// `POST /api/jobs/:id/trigger`, `POST /api/jobs/:id/builds/:n/cancel`)
    /// require an `Authorization: Bearer <token>` header. GET routes,
    /// the WebSocket log stream, and the public webhook stay open
    /// (the webhook has its own `webhookToken` knob). If nil, all
    /// routes are unauthenticated — suitable for trusted-network use
    /// only.
    public static func configure(
        _ app: Application,
        store: JobStore,
        executor: BuildExecutor,
        publicDirectory: String? = nil,
        webhookToken: String? = nil,
        adminToken: String? = nil,
        tokenStore: APITokenStore? = nil,
        credentialStore: CredentialStore? = nil
    ) {
        app.storage[JobStoreKey.self] = store
        app.storage[BuildExecutorKey.self] = executor

        if let dir = publicDirectory,
           FileManager.default.fileExists(atPath: dir) {
            app.middleware.use(FileMiddleware(publicDirectory: dir))
            // FileMiddleware in this kit version doesn't auto-resolve
            // `/` to `index.html` — redirect explicitly so the bare
            // hostname lands on the SPA. If no public dir is set, `/`
            // remains a 404 (operators can still hit /health, /version).
            app.get { req in req.redirect(to: "/index.html", redirectType: .permanent) }
        }

        // The text "<product> <version>\n" banner is exposed at
        // /version so it stays curl-able as a smoke check.
        app.get("version") { _ in "\(productName) \(version)\n" }
        app.get("health") { _ in "ok" }

        app.get("api", "jobs") { req -> Response in
            let ids = try store.listJobIDs()
            let payload = try JSONEncoder().encode(JobListResponse(jobs: ids))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        app.on(.POST, "api", "jobs", body: .collect(maxSize: "256kb")) { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let buf = req.body.data else {
                throw Abort(.badRequest, reason: "missing request body")
            }
            guard let yaml = buf.getString(at: buf.readerIndex, length: buf.readableBytes) else {
                throw Abort(.badRequest, reason: "request body is not valid UTF-8")
            }
            let pipeline: Pipeline
            do {
                pipeline = try Pipeline.decode(yaml: yaml)
            } catch PipelineError.empty {
                throw Abort(.badRequest, reason: "pipeline body is empty")
            } catch {
                throw Abort(.badRequest, reason: "could not parse pipeline YAML: \(error)")
            }
            let id = try store.createJob(from: pipeline)
            let payload = try JSONEncoder().encode(JobCreatedResponse(id: id, name: pipeline.name))
            return Response(
                status: .created,
                headers: HTTPHeaders([
                    ("content-type", "application/json; charset=utf-8"),
                    ("location", "/api/jobs/\(id)"),
                ]),
                body: .init(data: payload)
            )
        }

        app.get("api", "jobs", ":id") { req -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard let pipeline = try store.loadJob(id: id) else {
                throw Abort(.notFound, reason: "no such job: \(id)")
            }
            let yaml = try pipeline.encodeYAML()
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/x-yaml; charset=utf-8")]),
                body: .init(string: yaml)
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Build routes (Phase 3)
        // ──────────────────────────────────────────────────────────────

        app.on(.POST, "api", "jobs", ":id", "trigger",
               body: .collect(maxSize: "64kb")) { req async throws -> Response in
            try await Self.requireScope(.trigger, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard try store.loadJob(id: id) != nil else {
                throw Abort(.notFound, reason: "no such job: \(id)")
            }
            // Phase 33: optional JSON body `{"parameters":{"K":"V"}}`
            // overrides Phase-24 `parameters{}` defaults at trigger
            // time. An empty/missing body keeps the legacy no-arg
            // behavior. Non-string values are rejected with 400.
            var parameters: [String: String]? = nil
            if let buf = req.body.data, buf.readableBytes > 0,
               let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) {
                let data = Data(bytes)
                // Tolerate whitespace-only bodies (e.g. clients that
                // POST `\n` from a heredoc).
                let trimmed = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    struct TriggerBody: Decodable {
                        let parameters: [String: TriggerValue]?
                    }
                    enum TriggerValue: Decodable {
                        case string(String)
                        init(from decoder: Decoder) throws {
                            let c = try decoder.singleValueContainer()
                            if let s = try? c.decode(String.self) {
                                self = .string(s); return
                            }
                            throw Abort(.badRequest,
                                reason: "trigger parameter values must be strings")
                        }
                        var stringValue: String {
                            switch self { case .string(let s): return s }
                        }
                    }
                    let body: TriggerBody
                    do {
                        body = try JSONDecoder().decode(TriggerBody.self, from: data)
                    } catch let abort as AbortError {
                        throw abort
                    } catch {
                        throw Abort(.badRequest,
                            reason: "trigger body is not valid JSON: \(error)")
                    }
                    if let p = body.parameters, !p.isEmpty {
                        var out: [String: String] = [:]
                        for (k, v) in p { out[k] = v.stringValue }
                        parameters = out
                    }
                }
            }
            let number: Int
            do {
                number = try await executor.enqueue(jobID: id, parameters: parameters)
            } catch JobStoreError.noSuchJob(let badID) {
                throw Abort(.notFound, reason: "no such job: \(badID)")
            } catch {
                // Surface the underlying error in the response so test
                // failures and curl-driven debugging don't need to grep
                // server logs.
                throw Abort(.internalServerError, reason: "enqueue failed: \(error)")
            }
            let payload = try JSONEncoder().encode(BuildQueuedResponse(number: number))
            return Response(
                status: .accepted,
                headers: HTTPHeaders([
                    ("content-type", "application/json; charset=utf-8"),
                    ("location", "/api/jobs/\(id)/builds/\(number)"),
                ]),
                body: .init(data: payload)
            )
        }

        app.get("api", "jobs", ":id", "builds") { req -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard try store.loadJob(id: id) != nil else {
                throw Abort(.notFound, reason: "no such job: \(id)")
            }
            let numbers = try store.listBuildNumbers(jobID: id)
            let payload = try BuildExecutor.responseEncoder.encode(
                BuildListResponse(builds: numbers))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        app.get("api", "jobs", ":id", "builds", ":n") { req -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard let nString = req.parameters.get("n"), let n = Int(nString) else {
                throw Abort(.badRequest, reason: "missing or non-integer :n")
            }
            guard let build = try store.loadBuild(jobID: id, number: n) else {
                throw Abort(.notFound, reason: "no such build: \(id)#\(n)")
            }
            let log = (try? store.readLog(jobID: id, number: n, tail: 100)) ?? ""
            let payload = try BuildExecutor.responseEncoder.encode(
                BuildDetailResponse(build: build, log: log))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Live log streaming via WebSocket (Phase 4)
        // ──────────────────────────────────────────────────────────────
        //
        // Protocol:
        //   - On upgrade, server sends a "snapshot" frame containing
        //     the last 100 lines of the persisted log (in case the
        //     client connects mid-build or after-the-fact).
        //   - Server then forwards every live `appendLog(...)` chunk as
        //     a text frame.
        //   - When the build reaches a terminal state, the broadcaster
        //     finishes the subscriber stream; the route closes the WS
        //     with `.normalClosure`.
        //   - The route closes immediately with `.unsupportedData` if
        //     the build doesn't exist.
        app.webSocket("api", "jobs", ":id", "builds", ":n", "log", "stream") { req, ws in
            guard let id = req.parameters.get("id"),
                  let nString = req.parameters.get("n"),
                  let n = Int(nString) else {
                try? await ws.close(code: .unacceptableData)
                return
            }
            // Validate the build exists. If not, close immediately.
            do {
                guard try store.loadBuild(jobID: id, number: n) != nil else {
                    try? await ws.close(code: .unacceptableData)
                    return
                }
            } catch {
                try? await ws.close(code: .unexpectedServerError)
                return
            }

            // Subscribe FIRST so any chunks emitted between snapshot
            // capture and live-stream start are not dropped.
            let stream = await executor.broadcaster.subscribe(jobID: id, number: n)

            // Send snapshot (last 100 lines) so clients have context.
            let snapshot = (try? store.readLog(jobID: id, number: n, tail: 100)) ?? ""
            if !snapshot.isEmpty {
                try? await ws.send(snapshot)
            }

            // Pump live chunks. The stream finishes when the build
            // reaches a terminal state (broadcaster.finish was called).
            for await chunk in stream {
                if ws.isClosed { break }
                try? await ws.send(chunk)
            }
            try? await ws.close(code: .normalClosure)
        }

        // ──────────────────────────────────────────────────────────────
        // Agent dispatch endpoint (Phase 14)
        // ──────────────────────────────────────────────────────────────
        //
        // `WS /agents` accepts a connection from a swiftci-agent
        // process. The agent must:
        //   1. Authenticate via either `?token=<adminToken>` query OR
        //      an `Authorization: Bearer <adminToken>` header if
        //      `adminToken` is set on the controller.
        //   2. Send a `register` message as its first frame.
        //
        // After registration the agent receives `runBuild` /
        // `cancelBuild` and replies with `log` / `buildFinished`.
        // See `AgentProtocol.swift` for the message schema.
        app.webSocket("agents") { req, ws in
            // Token check (open if adminToken is nil).
            if let expected = adminToken {
                let header = req.headers["Authorization"].first
                let supplied: String
                if let header, header.hasPrefix("Bearer ") {
                    supplied = String(header.dropFirst("Bearer ".count))
                } else if let q: String = req.query["token"] {
                    supplied = q
                } else {
                    supplied = ""
                }
                if !Self.constantTimeEquals(expected, supplied) {
                    try? await ws.close(code: .unacceptableData)
                    return
                }
            }

            // Funnel every frame through a single AsyncStream. The
            // websocket-kit `WebSocket` stores its callbacks inside
            // `NIOLoopBoundBox`, whose setter `preconditionInEventLoop`
            // hard-fatals (NIOLoopBound.swift:172) if it isn't called
            // on the channel's event loop. Inside this `async` handler
            // we're running on the cooperative pool, NOT the WS loop,
            // so we MUST schedule the callback registration via
            // `ws.eventLoop.submit { ... }.get()`.
            let (frames, framesCont) = AsyncStream<String>.makeStream()
            try? await ws.eventLoop.submit {
                ws.onText { _, text in
                    framesCont.yield(text)
                }
                ws.onClose.whenComplete { _ in
                    framesCont.finish()
                }
            }.get()

            var iterator = frames.makeAsyncIterator()

            // First frame must be `register`.
            guard let firstFrame = await iterator.next() else {
                try? await ws.close(code: .unacceptableData)
                return
            }
            let registerPayload: AgentMessage.Register
            if let msg = try? AgentMessage.decode(json: firstFrame),
               case .register(let payload) = msg {
                registerPayload = payload
            } else {
                try? await ws.close(code: .unacceptableData)
                return
            }

            // Build the RemoteAgent + register it.
            let agent = RemoteAgent(
                name: registerPayload.name,
                labels: registerPayload.labels,
                agentVersion: registerPayload.agentVersion,
                ws: ws)
            await executor.agents.register(agent)
            let agentID = await agent.id
            req.logger.notice("agent registered: \(registerPayload.name) (labels: \(registerPayload.labels))")

            // Pump remaining frames to the agent until the WS closes
            // (which causes the stream to finish).
            while let text = await iterator.next() {
                await agent.receive(text)
            }

            await agent.didDisconnect()
            await executor.agents.unregister(id: agentID)
            req.logger.notice("agent disconnected: \(registerPayload.name)")
        }

        // `GET /api/agents` returns the current set of registered
        // agents. Used by operators and the smoke test to confirm an
        // agent has actually joined before dispatching a build.
        app.get("api", "agents") { req async throws -> Response in
            let snapshot = await executor.agents.snapshot()
            let payload = try JSONEncoder().encode(AgentListResponse(agents: snapshot))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        // Phase 22: read-only snapshot of the executor's FIFO queue.
        // Open by design — same threat model as `/metrics` (no job
        // names beyond what `GET /api/jobs` already exposes, no log
        // content). Operators / dashboards use this to answer "what's
        // actually waiting right now?" without scraping the slower
        // `/api/jobs/:id/builds/:n` per-build endpoint.
        app.get("api", "queue") { req async throws -> Response in
            let entries = await executor.snapshotQueue()
            let payload = try BuildExecutor.responseEncoder.encode(
                QueueListResponse(depth: entries.count, builds: entries))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Phase 28: cross-job recent terminal builds.
        // ──────────────────────────────────────────────────────────────
        //
        // `GET /api/builds/recent?limit=N` returns the most recently
        // ended terminal builds across every job, newest first. This
        // is the dashboard counterpart to `/api/queue`: the queue
        // shows what's pending; this endpoint shows what just
        // finished. Walks the same persisted store the metrics
        // handler already does — bounded by the retention policy
        // (default 50 per job) so cost is small.
        //
        // Query params:
        //   - `limit` — 1..200, default 20. Out-of-range or
        //     non-integer → 400.
        //
        // Sort key: `endedAt` desc, then `(jobID, number)` for
        // determinism when two builds finished at the same instant.
        app.get("api", "builds", "recent") { req -> Response in
            let limit: Int
            if let raw = req.query[String.self, at: "limit"] {
                guard let n = Int(raw), n >= 1, n <= 200 else {
                    throw Abort(.badRequest, reason: "limit must be an integer in 1..200")
                }
                limit = n
            } else {
                limit = 20
            }
            // Phase 29: optional `status` and `jobID` filters.
            // `status` is validated against the terminal subset
            // (passed/failed/canceled) — querying for `queued` or
            // `running` would always return [] since this endpoint
            // is terminal-only, so reject those with 400 to keep
            // API misuse loud rather than silently empty.
            let statusFilter: String?
            if let raw = req.query[String.self, at: "status"] {
                let allowed: Set<String> = ["passed", "failed", "canceled"]
                guard allowed.contains(raw) else {
                    throw Abort(.badRequest, reason: "status must be one of passed|failed|canceled")
                }
                statusFilter = raw
            } else {
                statusFilter = nil
            }
            // `jobID`, when present, restricts the walk to a single
            // job. Unknown ids are NOT a 404 — an empty result list
            // is the natural answer ("no recent builds for that
            // job"), and 404 would conflate "no such job" with "job
            // exists but has no terminal builds yet". Callers who
            // need existence checks should hit `/api/jobs/:id`.
            let jobFilter = req.query[String.self, at: "jobID"]

            var all: [RecentBuildEntry] = []
            let jobIDs: [String]
            if let f = jobFilter {
                jobIDs = ((try? store.listJobIDs()) ?? []).filter { $0 == f }
            } else {
                jobIDs = (try? store.listJobIDs()) ?? []
            }
            for jid in jobIDs {
                let nums = (try? store.listBuildNumbers(jobID: jid)) ?? []
                for n in nums {
                    guard let b = try? store.loadBuild(jobID: jid, number: n) else { continue }
                    guard b.status.isTerminal else { continue }
                    if let s = statusFilter, b.status.rawValue != s { continue }
                    let dur: Double?
                    if let s = b.startedAt, let e = b.endedAt {
                        dur = max(0, e.timeIntervalSince(s))
                    } else {
                        dur = nil
                    }
                    all.append(RecentBuildEntry(
                        jobID: jid,
                        number: b.number,
                        status: b.status.rawValue,
                        queuedAt: b.queuedAt,
                        startedAt: b.startedAt,
                        endedAt: b.endedAt,
                        durationSeconds: dur
                    ))
                }
            }
            // Sort by endedAt desc; nil endedAt sorts last. Tiebreak
            // by (jobID asc, number desc) so output is deterministic.
            all.sort { lhs, rhs in
                switch (lhs.endedAt, rhs.endedAt) {
                case let (l?, r?):
                    if l != r { return l > r }
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if lhs.jobID != rhs.jobID { return lhs.jobID < rhs.jobID }
                return lhs.number > rhs.number
            }
            let trimmed = Array(all.prefix(limit))
            let payload = try BuildExecutor.responseEncoder.encode(
                RecentBuildsResponse(
                    limit: limit,
                    statusFilter: statusFilter,
                    jobIDFilter: jobFilter,
                    builds: trimmed))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Phase 30: aggregate JSON dashboard summary at /api/stats.
        // ──────────────────────────────────────────────────────────────
        //
        // Same aggregates the Prometheus `/metrics` endpoint exposes,
        // but as plain JSON for callers that don't want to run a Prom
        // text-format parser (small dashboards, status pages, CLI
        // tooling). Open by design — exposes only counts and per-job
        // status totals, no log content or job-name metadata that
        // isn't already on `GET /api/jobs`. Walks the same persisted
        // store as `/metrics`, so cost is bounded by the retention
        // policy (default 50 builds/job).
        app.get("api", "stats") { req async throws -> Response in
            let depth = await executor.queueDepth
            let queueSnap = await executor.snapshotQueue()
            let now = Date()
            let oldestAge: Double = queueSnap
                .map { now.timeIntervalSince($0.queuedAt) }
                .filter { $0 >= 0 }
                .max() ?? 0
            let agentsSnap = await executor.agents.snapshot()
            var idle = 0, busy = 0, disconnected = 0
            for a in agentsSnap {
                if a.isDisconnected { disconnected += 1 }
                else if a.isBusy { busy += 1 }
                else { idle += 1 }
            }
            var counts: [String: Int] = [:]
            var jobCounts: [String: [String: Int]] = [:]
            let jobIDs = (try? store.listJobIDs()) ?? []
            for jid in jobIDs {
                let nums = (try? store.listBuildNumbers(jobID: jid)) ?? []
                for n in nums {
                    if let b = try? store.loadBuild(jobID: jid, number: n) {
                        counts[b.status.rawValue, default: 0] += 1
                        jobCounts[jid, default: [:]][b.status.rawValue, default: 0] += 1
                    }
                }
            }
            // Stable label set so callers don't need to handle
            // missing keys. Mirrors how `swiftci_builds{status}`
            // emits all five buckets.
            for s in ["queued", "running", "passed", "failed", "canceled"] {
                if counts[s] == nil { counts[s] = 0 }
            }
            let payload = try BuildExecutor.responseEncoder.encode(
                StatsResponse(
                    version: SwiftCIApp.version,
                    jobs: jobIDs.count,
                    queueDepth: depth,
                    queueOldestAgeSeconds: oldestAge,
                    agentsIdle: idle,
                    agentsBusy: busy,
                    agentsDisconnected: disconnected,
                    buildsByStatus: counts,
                    buildsByJobStatus: jobCounts,
                    processStartTimeUnixSeconds:
                        SwiftCIApp.processStartTimeUnixSeconds))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Phase 19: Prometheus-format /metrics endpoint
        // ──────────────────────────────────────────────────────────────
        //
        // Open by design — Prometheus scrapers don't authenticate.
        // Operators who need access control should put swiftci behind
        // a reverse proxy that strips/adds an auth header for /metrics
        // independently of the regular API surface. The endpoint
        // exposes only aggregate counts (no job names, no log content)
        // so leakage risk is low even when accidentally public.
        app.get("metrics") { req async throws -> Response in
            let depth = await executor.queueDepth
            let queueSnap = await executor.snapshotQueue()
            // Phase 22: oldest queued-build age. 0 when the queue is
            // empty. Computed at scrape time from `Date()` so the
            // gauge climbs in real time without the executor having
            // to push updates.
            let now = Date()
            let oldestAge: Double = queueSnap
                .map { now.timeIntervalSince($0.queuedAt) }
                .filter { $0 >= 0 }
                .max() ?? 0
            let agents = await executor.agents.snapshot()
            var idle = 0, busy = 0, disconnected = 0
            for a in agents {
                if a.isDisconnected { disconnected += 1 }
                else if a.isBusy { busy += 1 }
                else { idle += 1 }
            }
            // Walk all jobs × all builds. Bounded by the retention
            // policy (default 50 per job) so this stays cheap.
            var counts: [String: Int] = [:]
            var durations: [String: [Double]] = [:]
            var queueWaits: [Double] = []
            // Phase 27: per-job build counts by status. Same data the
            // global `swiftci_builds{status}` gauge sums, but kept
            // bucketed by job id so dashboards can show per-pipeline
            // pass/fail trends.
            var jobCounts: [String: [String: Int]] = [:]
            // Phase 23: most recent terminal build per job (by build
            // number, the source of truth for ordering). Built in the
            // same single-pass walk so we don't reload anything.
            var lastBuild: [String: MetricsExposition.Snapshot.LastBuildInfo] = [:]
            var lastBuildNumber: [String: Int] = [:]
            let jobIDs = (try? store.listJobIDs()) ?? []
            for jid in jobIDs {
                let nums = (try? store.listBuildNumbers(jobID: jid)) ?? []
                for n in nums {
                    if let b = try? store.loadBuild(jobID: jid, number: n) {
                        counts[b.status.rawValue, default: 0] += 1
                        // Phase 27: track per-job too.
                        jobCounts[jid, default: [:]][b.status.rawValue, default: 0] += 1
                        // Phase 20: record wall-clock duration when we
                        // have both timestamps. Builds in non-terminal
                        // states (.queued / .running) won't have
                        // `endedAt` and are skipped.
                        if b.status.isTerminal,
                           let started = b.startedAt,
                           let ended = b.endedAt {
                            let d = ended.timeIntervalSince(started)
                            if d >= 0 {
                                durations[b.status.rawValue, default: []].append(d)
                            }
                        }
                        // Phase 21: queue-wait time. Skipped for
                        // builds still queued (no `startedAt`) and for
                        // older persisted builds with no `queuedAt`.
                        if let queued = b.queuedAt,
                           let started = b.startedAt {
                            let w = started.timeIntervalSince(queued)
                            if w >= 0 { queueWaits.append(w) }
                        }
                        // Phase 23: track the highest-numbered terminal
                        // build per job, with its endedAt. Only
                        // terminal builds count — a .running build
                        // isn't a "last result" yet.
                        if b.status.isTerminal, let ended = b.endedAt,
                           n > (lastBuildNumber[jid] ?? 0) {
                            lastBuildNumber[jid] = n
                            // Phase 25: include wall-clock duration
                            // when both timestamps are present so
                            // /metrics can render the matching
                            // `_last_build_duration_seconds` gauge.
                            var dur: Double? = nil
                            if let started = b.startedAt {
                                let d = ended.timeIntervalSince(started)
                                if d >= 0 { dur = d }
                            }
                            lastBuild[jid] = .init(
                                number: n,
                                status: b.status.rawValue,
                                endedAtUnixSeconds: ended.timeIntervalSince1970,
                                durationSeconds: dur
                            )
                        }
                    }
                }
            }
            let snap = MetricsExposition.Snapshot(
                version: Self.version,
                queueDepth: depth,
                jobs: jobIDs.count,
                agentsIdle: idle,
                agentsBusy: busy,
                agentsDisconnected: disconnected,
                buildsByStatus: counts,
                durationsByStatus: durations,
                queueWaitsSeconds: queueWaits,
                queueOldestAgeSeconds: oldestAge,
                lastBuildByJob: lastBuild,
                processStartTimeUnixSeconds: Self.processStartTimeUnixSeconds,
                jobBuildsByStatus: jobCounts
            )
            let body = MetricsExposition.render(snap)
            return Response(
                status: .ok,
                headers: HTTPHeaders([
                    ("content-type", MetricsExposition.contentType),
                ]),
                body: .init(string: body)
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Artifacts (Phase 7)
        // ──────────────────────────────────────────────────────────────
        //
        // - `GET /api/jobs/:id/builds/:n/artifacts` returns
        //   `{artifacts: [name]}` sorted lexicographically.
        // - `GET /api/jobs/:id/builds/:n/artifacts/:name` streams the
        //   raw artifact bytes back via `req.fileio.asyncStreamFile`,
        //   forcing `application/octet-stream` so browsers reliably
        //   download rather than render.
        app.get("api", "jobs", ":id", "builds", ":n", "artifacts") { req -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard let nString = req.parameters.get("n"), let n = Int(nString) else {
                throw Abort(.badRequest, reason: "missing or non-integer :n")
            }
            guard try store.loadBuild(jobID: id, number: n) != nil else {
                throw Abort(.notFound, reason: "no such build: \(id)#\(n)")
            }
            let names = try store.listArtifacts(jobID: id, number: n)
            let payload = try BuildExecutor.responseEncoder.encode(
                ArtifactListResponse(artifacts: names))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload)
            )
        }

        app.get("api", "jobs", ":id", "builds", ":n", "artifacts", ":name") { req async throws -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard let nString = req.parameters.get("n"), let n = Int(nString) else {
                throw Abort(.badRequest, reason: "missing or non-integer :n")
            }
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "missing :name")
            }
            guard try store.loadBuild(jobID: id, number: n) != nil else {
                throw Abort(.notFound, reason: "no such build: \(id)#\(n)")
            }
            guard let url = store.artifactURL(jobID: id, number: n, name: name) else {
                throw Abort(.notFound, reason: "no such artifact: \(name)")
            }
            // Reject directory downloads for v0 — we have no archive
            // step. Steps that need a directory should tar/zip first.
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                throw Abort(.unsupportedMediaType,
                            reason: "artifact is a directory; archive it in the step before downloading")
            }
            let response = try await req.fileio.asyncStreamFile(at: url.path)
            // Force download with the artifact's basename, not the
            // request path.
            response.headers.replaceOrAdd(
                name: "content-type", value: "application/octet-stream")
            response.headers.replaceOrAdd(
                name: "content-disposition",
                value: "attachment; filename=\"\(url.lastPathComponent)\"")
            return response
        }

        // ──────────────────────────────────────────────────────────────
        // Build cancellation (Phase 8)
        // ──────────────────────────────────────────────────────────────
        //
        // `POST /api/jobs/:id/builds/:n/cancel`
        //   - 200 + `{result: "canceledRunning"}` if the build was
        //     mid-step (the child process is terminated; the on-disk
        //     status flips to `.canceled` once `waitUntilExit` returns).
        //   - 200 + `{result: "canceledQueued"}` if it was waiting in
        //     the queue.
        //   - 404 if the build doesn't exist.
        //   - 409 if the build is already in a terminal state.
        app.post("api", "jobs", ":id", "builds", ":n", "cancel") { req async throws -> Response in
            try await Self.requireScope(.trigger, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            guard let nString = req.parameters.get("n"), let n = Int(nString) else {
                throw Abort(.badRequest, reason: "missing or non-integer :n")
            }
            guard let build = try store.loadBuild(jobID: id, number: n) else {
                throw Abort(.notFound, reason: "no such build: \(id)#\(n)")
            }
            let result = await executor.cancel(jobID: id, number: n)
            switch result {
            case .canceledRunning, .canceledQueued:
                let payload = try JSONEncoder().encode(
                    CancelResponse(result: result == .canceledRunning
                                   ? "canceledRunning" : "canceledQueued"))
                return Response(
                    status: .ok,
                    headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                    body: .init(data: payload)
                )
            case .notCancellable:
                throw Abort(.conflict,
                            reason: "build is already \(build.status.rawValue)")
            }
        }

        // ──────────────────────────────────────────────────────────────
        // API token management (Phase 35)
        // ──────────────────────────────────────────────────────────────
        //
        // The dashboard / CLI manages persistent API tokens through:
        //   GET    /api/tokens          → list metadata (no secrets)
        //   POST   /api/tokens          → mint a token, returns secret
        //   DELETE /api/tokens/:id      → revoke
        //
        // All three routes require the `.admin` scope. If no
        // `tokenStore` is configured the routes return 503; the legacy
        // single-admin deployment (`adminToken` only) is unaffected
        // because callers simply don't reach these endpoints in that
        // mode.

        app.get("api", "tokens") { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let tokenStore else {
                throw Abort(.serviceUnavailable, reason: "token store not configured")
            }
            let tokens = try await tokenStore.list()
            let dtos = tokens.map { t in
                TokenListItem(id: t.id, name: t.name,
                              scopes: t.scopes.map { $0.rawValue },
                              createdAt: t.createdAt)
            }
            let payload = try Self.tokenJSONEncoder().encode(
                TokenListResponse(tokens: dtos))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload))
        }

        app.on(.POST, "api", "tokens",
               body: .collect(maxSize: "16kb")) { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let tokenStore else {
                throw Abort(.serviceUnavailable, reason: "token store not configured")
            }
            guard let buf = req.body.data,
                  let json = buf.getString(at: buf.readerIndex, length: buf.readableBytes),
                  let data = json.data(using: .utf8) else {
                throw Abort(.badRequest, reason: "missing or non-UTF-8 body")
            }
            let body: CreateTokenRequest
            do {
                body = try JSONDecoder().decode(CreateTokenRequest.self, from: data)
            } catch {
                throw Abort(.badRequest, reason: "invalid JSON body: \(error)")
            }
            var scopes: [APITokenStore.Scope] = []
            for raw in body.scopes {
                guard let s = APITokenStore.Scope(rawValue: raw) else {
                    throw Abort(.badRequest, reason: "unknown scope: \(raw)")
                }
                scopes.append(s)
            }
            let token: APITokenStore.Token
            do {
                token = try await tokenStore.create(name: body.name, scopes: scopes)
            } catch APITokenStore.CreateError.nameEmpty {
                throw Abort(.badRequest, reason: "name must be non-empty")
            } catch APITokenStore.CreateError.scopesEmpty {
                throw Abort(.badRequest, reason: "scopes must be non-empty")
            } catch APITokenStore.CreateError.duplicateName(let n) {
                throw Abort(.conflict, reason: "token name already in use: \(n)")
            }
            let dto = CreateTokenResponse(
                id: token.id, name: token.name, secret: token.secret,
                scopes: token.scopes.map { $0.rawValue },
                createdAt: token.createdAt)
            let payload = try Self.tokenJSONEncoder().encode(dto)
            return Response(
                status: .created,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload))
        }

        app.delete("api", "tokens", ":id") { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let tokenStore else {
                throw Abort(.serviceUnavailable, reason: "token store not configured")
            }
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            do {
                try await tokenStore.delete(id: id)
            } catch APITokenStore.DeleteError.notFound {
                throw Abort(.notFound, reason: "no such token: \(id)")
            }
            return Response(status: .noContent)
        }

        // ──────────────────────────────────────────────────────────────
        // Credential management (Phase 37)
        // ──────────────────────────────────────────────────────────────
        //
        // `GET    /api/credentials`        → list metadata (no values)
        // `POST   /api/credentials`        → create a credential
        // `DELETE /api/credentials/:id`    → revoke
        //
        // All admin-scoped. 503 when no credentialStore is wired. The
        // listing endpoint redacts `value` unconditionally; the only
        // way a secret leaves the controller is via the executor's
        // env injection at build time.

        app.get("api", "credentials") { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let credentialStore else {
                throw Abort(.serviceUnavailable, reason: "credential store not configured")
            }
            let creds = try await credentialStore.list()
            let dtos = creds.map {
                CredentialListItem(
                    id: $0.id,
                    kind: $0.kind.rawValue,
                    description: $0.description,
                    createdAt: $0.createdAt)
            }
            let payload = try Self.tokenJSONEncoder().encode(
                CredentialListResponse(credentials: dtos))
            return Response(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload))
        }

        app.on(.POST, "api", "credentials",
               body: .collect(maxSize: "64kb")) { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let credentialStore else {
                throw Abort(.serviceUnavailable, reason: "credential store not configured")
            }
            guard let buf = req.body.data,
                  let json = buf.getString(at: buf.readerIndex, length: buf.readableBytes),
                  let data = json.data(using: .utf8) else {
                throw Abort(.badRequest, reason: "missing or non-UTF-8 body")
            }
            let body: CreateCredentialRequest
            do {
                body = try JSONDecoder().decode(CreateCredentialRequest.self, from: data)
            } catch {
                throw Abort(.badRequest, reason: "invalid JSON body: \(error)")
            }
            let kind: CredentialStore.Kind
            if let raw = body.kind {
                guard let k = CredentialStore.Kind(rawValue: raw) else {
                    throw Abort(.badRequest, reason: "unknown credential kind: \(raw)")
                }
                kind = k
            } else {
                kind = .string
            }
            let cred: CredentialStore.Credential
            do {
                cred = try await credentialStore.create(
                    id: body.id,
                    kind: kind,
                    description: body.description ?? "",
                    value: body.value)
            } catch CredentialStore.CreateError.idEmpty {
                throw Abort(.badRequest, reason: "id must be non-empty")
            } catch CredentialStore.CreateError.valueEmpty {
                throw Abort(.badRequest, reason: "value must be non-empty")
            } catch CredentialStore.CreateError.duplicateID(let id) {
                throw Abort(.conflict, reason: "credential id already in use: \(id)")
            }
            // The response intentionally does NOT echo `value` —
            // operators are expected to have it locally already.
            let dto = CredentialListItem(
                id: cred.id, kind: cred.kind.rawValue,
                description: cred.description, createdAt: cred.createdAt)
            let payload = try Self.tokenJSONEncoder().encode(dto)
            return Response(
                status: .created,
                headers: HTTPHeaders([("content-type", "application/json; charset=utf-8")]),
                body: .init(data: payload))
        }

        app.delete("api", "credentials", ":id") { req async throws -> Response in
            try await Self.requireScope(.admin, req: req,
                legacyAdmin: adminToken, tokenStore: tokenStore)
            guard let credentialStore else {
                throw Abort(.serviceUnavailable, reason: "credential store not configured")
            }
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            do {
                try await credentialStore.delete(id: id)
            } catch CredentialStore.DeleteError.notFound {
                throw Abort(.notFound, reason: "no such credential: \(id)")
            }
            return Response(status: .noContent)
        }

        // ──────────────────────────────────────────────────────────────
        // Webhook receiver (Phase 5)
        // ──────────────────────────────────────────────────────────────
        //
        // `POST /webhook/:id` triggers a build for `:id` the same way
        // the dashboard's `POST /api/jobs/:id/trigger` does, but with a
        // shape friendlier to external SCM hooks:
        //   - 202 Accepted on success with `{number, jobID}` JSON
        //   - body and content-type are NOT inspected (any payload is
        //     accepted; we may surface webhook payloads to the pipeline
        //     environment in a later phase)
        //   - 401 if `webhookToken` is configured but the request did
        //     not provide a matching `X-Webhook-Token` header OR
        //     `?token=...` query parameter
        //   - 404 if the job does not exist
        //
        // The token is a shared secret. For production behind a TLS
        // proxy this is sufficient; CSRF doesn't apply because the
        // route only accepts POST. If `webhookToken` is nil, the route
        // is unauthenticated — fine for trusted-network use, NOT for
        // public-internet deploys.
        app.on(.POST, "webhook", ":id", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "missing :id")
            }
            if let expected = webhookToken {
                let headerToken = req.headers["X-Webhook-Token"].first
                let queryToken: String? = req.query["token"]
                let supplied = headerToken ?? queryToken ?? ""
                if !Self.constantTimeEquals(expected, supplied) {
                    throw Abort(.unauthorized, reason: "invalid or missing webhook token")
                }
            }
            guard try store.loadJob(id: id) != nil else {
                throw Abort(.notFound, reason: "no such job: \(id)")
            }

            // Capture the inbound payload so the build's steps can
            // read it via `SWIFTCI_WEBHOOK_BODY_PATH`. The Vapor token
            // header is stripped from the persisted headers so we
            // don't write secrets to disk under any circumstance.
            var headerMap: [String: String] = [:]
            for (name, value) in req.headers {
                let lower = name.lowercased()
                if lower == "x-webhook-token" { continue }
                if let existing = headerMap[lower] {
                    headerMap[lower] = existing + ", " + value
                } else {
                    headerMap[lower] = value
                }
            }
            var rawBody = Data()
            if let buf = req.body.data {
                rawBody = Data(buffer: buf)
            }
            let payload = WebhookPayload(
                method: req.method.string,
                receivedAt: Date(),
                headers: headerMap,
                rawBody: rawBody
            )

            let number: Int
            do {
                number = try await executor.enqueue(jobID: id, webhookPayload: payload)
            } catch JobStoreError.noSuchJob(let badID) {
                throw Abort(.notFound, reason: "no such job: \(badID)")
            } catch {
                throw Abort(.internalServerError, reason: "enqueue failed: \(error)")
            }
            let responseBody = try JSONEncoder().encode(WebhookAcceptedResponse(
                jobID: id, number: number))
            return Response(
                status: .accepted,
                headers: HTTPHeaders([
                    ("content-type", "application/json; charset=utf-8"),
                    ("location", "/api/jobs/\(id)/builds/\(number)"),
                ]),
                body: .init(data: responseBody)
            )
        }
    }

    /// Constant-time byte comparison to avoid leaking token length /
    /// prefix via timing. Comparing UTF-8 byte counts handles
    /// multi-byte ASCII/UTF-8 identically.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    /// Throws `Abort(.unauthorized)` if `expected` is non-nil and the
    /// request does not carry a matching `Authorization: Bearer ...`
    /// header. Pass `nil` to disable the check entirely (open
    /// deployment).
    static func requireAdmin(req: Request, expected: String?) throws {
        guard let expected else { return }
        guard let header = req.headers["Authorization"].first,
              header.hasPrefix("Bearer ") else {
            throw Abort(.unauthorized, reason: "missing or malformed Authorization header")
        }
        let supplied = String(header.dropFirst("Bearer ".count))
        guard constantTimeEquals(expected, supplied) else {
            throw Abort(.unauthorized, reason: "invalid admin token")
        }
    }

    /// Phase 35: scope-checked auth. The request is authorized if
    /// **any** of the following holds:
    ///
    /// - Both `legacyAdmin` and `tokenStore` are nil (open deployment).
    /// - `legacyAdmin` is set and the Bearer token matches it exactly
    ///   (treated as `.admin` scope, satisfies anything).
    /// - `tokenStore` is set, the Bearer token matches a stored token,
    ///   and that token's scope set satisfies `required`.
    ///
    /// When both `legacyAdmin` and `tokenStore` are set the legacy
    /// match is tried first so existing single-admin deployments
    /// continue working unchanged.
    static func requireScope(
        _ required: APITokenStore.Scope,
        req: Request,
        legacyAdmin: String?,
        tokenStore: APITokenStore?
    ) async throws {
        // Open deployment.
        if legacyAdmin == nil && tokenStore == nil { return }
        guard let header = req.headers["Authorization"].first,
              header.hasPrefix("Bearer ") else {
            throw Abort(.unauthorized,
                reason: "missing or malformed Authorization header")
        }
        let supplied = String(header.dropFirst("Bearer ".count))
        if let legacy = legacyAdmin,
           APITokenStore.constantTimeEquals(legacy, supplied) {
            return // admin equivalent
        }
        if let tokenStore {
            let match = try await tokenStore.lookup(secret: supplied)
            if let t = match,
               APITokenStore.satisfies(scopes: t.scopes, required: required) {
                return
            }
        }
        throw Abort(.unauthorized,
            reason: "token missing required scope: \(required.rawValue)")
    }
}

// ──────────────────────────────────────────────────────────────────────
// DTOs & storage keys
// ──────────────────────────────────────────────────────────────────────

private struct JobListResponse: Codable {
    let jobs: [String]
}

private struct JobCreatedResponse: Codable {
    let id: String
    let name: String
}

private struct BuildQueuedResponse: Codable {
    let number: Int
}

private struct BuildListResponse: Codable {
    let builds: [Int]
}

private struct BuildDetailResponse: Codable {
    let build: Build
    let log: String
}

private struct WebhookAcceptedResponse: Codable {
    let jobID: String
    let number: Int
}

private struct ArtifactListResponse: Codable {
    let artifacts: [String]
}

private struct CancelResponse: Codable {
    let result: String
}

private struct AgentListResponse: Codable {
    let agents: [AgentInfo]
}

private struct QueueListResponse: Codable {
    let depth: Int
    let builds: [BuildExecutor.QueueSnapshotEntry]
}

/// Phase 28: payload for `GET /api/builds/recent`. One entry per
/// terminal build (passed/failed/canceled). Field set is a strict
/// subset of `Build` plus a precomputed `durationSeconds` so
/// dashboards don't have to do date math themselves.
struct RecentBuildEntry: Codable, Equatable, Sendable {
    let jobID: String
    let number: Int
    let status: String
    let queuedAt: Date?
    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: Double?
}

struct RecentBuildsResponse: Codable, Equatable, Sendable {
    let limit: Int
    /// Phase 29: echo back the applied filters so callers can
    /// distinguish "no results" from "I forgot my filter typoed".
    let statusFilter: String?
    let jobIDFilter: String?
    let builds: [RecentBuildEntry]
}

/// Phase 30: payload for `GET /api/stats`. Mirrors the aggregate
/// surface of the Prometheus `/metrics` exposition so dashboards
/// can avoid parsing Prom text. Field set is intentionally a
/// strict subset — no histograms, no last-build-per-job (callers
/// that need those have `/metrics` or `/api/builds/recent`).
struct StatsResponse: Codable, Equatable, Sendable {
    let version: String
    let jobs: Int
    let queueDepth: Int
    let queueOldestAgeSeconds: Double
    let agentsIdle: Int
    let agentsBusy: Int
    let agentsDisconnected: Int
    let buildsByStatus: [String: Int]
    let buildsByJobStatus: [String: [String: Int]]
    let processStartTimeUnixSeconds: Double
}

extension BuildExecutor {
    /// Shared JSON encoder for build-related HTTP responses. ISO 8601
    /// dates + sorted keys keep payloads diff-friendly.
    public static let responseEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

/// Vapor `StorageKey` for the per-Application `JobStore`.
public struct JobStoreKey: StorageKey {
    public typealias Value = JobStore
}

/// Vapor `StorageKey` for the per-Application `BuildExecutor`.
public struct BuildExecutorKey: StorageKey {
    public typealias Value = BuildExecutor
}


// ──────────────────────────────────────────────────────────────────────
// Phase 35 — API token DTOs
// ──────────────────────────────────────────────────────────────────────

private struct TokenListItem: Codable {
    let id: String
    let name: String
    let scopes: [String]
    let createdAt: Date
}

private struct TokenListResponse: Codable {
    let tokens: [TokenListItem]
}

private struct CreateTokenRequest: Codable {
    let name: String
    let scopes: [String]
}

private struct CreateTokenResponse: Codable {
    let id: String
    let name: String
    let secret: String
    let scopes: [String]
    let createdAt: Date
}

// ──────────────────────────────────────────────────────────────────────
// Phase 37 — Credential DTOs
// ──────────────────────────────────────────────────────────────────────

private struct CredentialListItem: Codable {
    let id: String
    let kind: String
    let description: String
    let createdAt: Date
}

private struct CredentialListResponse: Codable {
    let credentials: [CredentialListItem]
}

private struct CreateCredentialRequest: Codable {
    let id: String
    let kind: String?
    let description: String?
    let value: String
}

extension SwiftCIApp {
    /// JSON encoder used by token routes; isolates the date strategy
    /// from other endpoints that hand-roll their own encoders.
    static func tokenJSONEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
