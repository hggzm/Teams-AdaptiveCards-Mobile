import Foundation
import Vapor
import Crypto

/// Filesystem-backed webhook subscription store + async dispatcher.
///
/// On-disk shape (sibling of issues.json / prs.json):
///
///     <root>/.giteax/repos/<user>/<repo>/webhooks.json
///       {
///         "version": 1,
///         "nextHookID": 5,
///         "nextDeliveryID": 42,
///         "hooks": [
///           { id, url, secret?, events[], active,
///             createdAt, lastDeliveredAt?, lastStatus? }
///         ],
///         "deliveries": [
///           // last N deliveries (ring buffer, size = 50 per hook)
///           { id, hookID, event, url, attempts, lastStatus,
///             lastError?, deliveredAt, durationMs }
///         ]
///       }
///
/// Events supported in v0.0.10: `push`, `pull_request`, `issue`,
/// `issue_comment`, `pull_request_comment`, `ping`.
///
/// Dispatch model:
///   - Per (event, hook) match, spawn a Task that POSTs the JSON
///     body to `hook.url`. Vapor's `app.client` is used for the
///     send. Body is signed with HMAC-SHA256 over the raw bytes
///     using the hook's secret (omitted when no secret is set).
///   - Up to 3 attempts with exponential backoff (1s, 4s, 16s).
///   - Each attempt updates the persisted delivery record; the
///     hook's `lastDeliveredAt` / `lastStatus` are updated on
///     final success or final failure.
///
/// HTTPS targets: AsyncHTTPClient via Vapor `app.client` supports
/// HTTPS on Windows since the Vapor Phase F pin-bump (2026-05-18).
/// Self-signed certs on receivers won't work without a custom
/// TLS config -- documented limitation.
actor WebhookStore {

    // MARK: - Records

    static let supportedEvents: Set<String> = [
        "push",
        "pull_request",
        "pull_request_review",
        "issue",
        "issue_comment",
        "pull_request_comment",
        "workflow_run",
        "ping",
    ]

    struct Hook: Sendable, Codable {
        let id: Int
        var url: String
        var secret: String?
        var events: [String]
        var active: Bool
        let createdAt: Date
        var lastDeliveredAt: Date?
        var lastStatus: Int?
        /// Phase 23: per-hook glob patterns matched against pushed ref
        /// names ("main", "feature/*", "release-?.x"). When non-empty,
        /// a push event must touch at least one matching ref to fire.
        /// Nil/empty -> match-all (legacy v0.0.13 behavior).
        var branchPatterns: [String]?
        /// Phase 24: per-hook delivery rate limit, in attempts per minute.
        /// Nil or <= 0 -> unbounded (legacy). When set, the dispatcher
        /// drops deliveries beyond the cap and records a synthetic
        /// `lastError: "rate-limited"` entry.
        var rateLimitPerMinute: Int?
    }

    struct Delivery: Sendable, Codable {
        let id: Int
        let hookID: Int
        let event: String
        let url: String
        var attempts: Int
        var lastStatus: Int?
        var lastError: String?
        var deliveredAt: Date
        var durationMs: Int
        /// Phase 21: persisted JSON payload bytes used by the redeliver
        /// endpoint. Optional for backwards compatibility with delivery
        /// records written by pre-0.0.13 builds. Capped at 64 KiB at
        /// store time; oversized payloads land as `nil` and that delivery
        /// can only be replayed as a synthetic ping (see WebhookRoutes).
        var body: Data?
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextHookID: Int
        var nextDeliveryID: Int
        var hooks: [Hook]
        var deliveries: [Delivery]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case hookNotFound(id: Int)
        case invalidEvent(String)
        case invalidURL(String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound, .hookNotFound: .notFound
            case .invalidEvent, .invalidURL, .invalidInput: .badRequest
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): "no repository at \(u)/\(r)"
            case .hookNotFound(let i):        "no webhook #\(i)"
            case .invalidEvent(let e):        "unsupported event '\(e)' (allowed: \(WebhookStore.supportedEvents.sorted().joined(separator: ", ")))"
            case .invalidURL(let u):          "invalid URL '\(u)' (must be http:// or https://)"
            case .invalidInput(let d):        "invalid webhook input: \(d)"
            case .ioFailed(let d):            "webhook-store I/O failed: \(d)"
            case .badEnvelope(let d):         "webhook-store JSON malformed: \(d)"
            }
        }
    }

    // MARK: - Init

    let root: URL
    /// Keep at most this many delivery records per repo in the envelope.
    private let deliveryRingSize = 200

    private var envelopes: [String: Envelope] = [:]

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.root = root
    }

    /// Phase 44: drop cached envelope for `user/repo`.
    func evictRepo(user: String, repo: String) {
        envelopes.removeValue(forKey: "\(user)/\(repo)")
    }

    // MARK: - Read

    func list(user: String, repo: String) throws -> [Hook] {
        let env = try loadOrInit(user: user, repo: repo)
        return env.hooks
    }

    func get(user: String, repo: String, id: Int) throws -> Hook {
        let env = try loadOrInit(user: user, repo: repo)
        guard let h = env.hooks.first(where: { $0.id == id }) else {
            throw StoreError.hookNotFound(id: id)
        }
        return h
    }

    /// Deliveries newest-first.
    func deliveries(user: String, repo: String, hookID: Int?, limit: Int = 50) throws -> [Delivery] {
        let env = try loadOrInit(user: user, repo: repo)
        var out = env.deliveries
        if let hookID { out = out.filter { $0.hookID == hookID } }
        out.sort { $0.id > $1.id }
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    /// Active hooks for `event`. Used by the dispatcher to fan out.
    func subscribers(user: String, repo: String, event: String) throws -> [Hook] {
        let env = try loadOrInit(user: user, repo: repo)
        return env.hooks.filter {
            $0.active && ($0.events.contains(event) || $0.events.contains("*"))
        }
    }

    // MARK: - Mutate

    @discardableResult
    func create(
        user: String, repo: String,
        url: String, secret: String?, events: [String], active: Bool,
        branchPatterns: [String]? = nil, rateLimitPerMinute: Int? = nil
    ) throws -> Hook {
        try Self.validateURL(url)
        let validatedEvents = try Self.validateEvents(events)
        if let p = branchPatterns { try Self.validatePatterns(p) }
        if let n = rateLimitPerMinute, n < 0 {
            throw StoreError.invalidInput("rateLimitPerMinute must be >= 0")
        }
        var env = try loadOrInit(user: user, repo: repo)
        let id = env.nextHookID
        env.nextHookID += 1
        let h = Hook(
            id: id, url: url, secret: secret,
            events: validatedEvents, active: active,
            createdAt: Date(), lastDeliveredAt: nil, lastStatus: nil,
            branchPatterns: (branchPatterns?.isEmpty == true) ? nil : branchPatterns,
            rateLimitPerMinute: (rateLimitPerMinute ?? 0) > 0 ? rateLimitPerMinute : nil
        )
        env.hooks.append(h)
        try persist(env, user: user, repo: repo)
        return h
    }

    func delete(user: String, repo: String, id: Int) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.hooks.contains(where: { $0.id == id }) else {
            throw StoreError.hookNotFound(id: id)
        }
        env.hooks.removeAll(where: { $0.id == id })
        // Keep delivery history for retention/audit -- they reference
        // the now-deleted hook by id but that's fine.
        try persist(env, user: user, repo: repo)
    }

    /// Update mutable fields. Pass nil to leave unchanged.
    @discardableResult
    func update(
        user: String, repo: String, id: Int,
        url: String? = nil, secret: String? = nil,
        events: [String]? = nil, active: Bool? = nil,
        branchPatterns: [String]? = nil, rateLimitPerMinute: Int? = nil
    ) throws -> Hook {
        if let url { try Self.validateURL(url) }
        let validatedEvents: [String]?
        if let events { validatedEvents = try Self.validateEvents(events) }
        else          { validatedEvents = nil }
        if let patterns = branchPatterns, !patterns.isEmpty {
            try Self.validatePatterns(patterns)
        }
        if let n = rateLimitPerMinute, n < 0 {
            throw StoreError.invalidInput("rateLimitPerMinute must be >= 0")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.hooks.firstIndex(where: { $0.id == id }) else {
            throw StoreError.hookNotFound(id: id)
        }
        var h = env.hooks[idx]
        if let url    { h.url = url }
        if let secret { h.secret = secret.isEmpty ? nil : secret }
        if let v = validatedEvents { h.events = v }
        if let active { h.active = active }
        if let patterns = branchPatterns {
            h.branchPatterns = patterns.isEmpty ? nil : patterns
        }
        if let n = rateLimitPerMinute {
            h.rateLimitPerMinute = n > 0 ? n : nil
        }
        env.hooks[idx] = h
        try persist(env, user: user, repo: repo)
        return h
    }

    /// Record a delivery attempt outcome. Updates the hook's
    /// lastDeliveredAt/lastStatus AND appends to the delivery ring.
    func recordDelivery(
        user: String, repo: String,
        hookID: Int, event: String, url: String,
        attempts: Int, status: Int?, error: String?, durationMs: Int,
        body: Data?
    ) throws {
        var env = try loadOrInit(user: user, repo: repo)
        let id = env.nextDeliveryID
        env.nextDeliveryID += 1
        // Cap stored body at 64 KiB to keep deliveries.json bounded.
        // Oversized payloads still record outcome, just lose replay-ability.
        let storedBody: Data? = {
            guard let body else { return nil }
            return body.count <= 64 * 1024 ? body : nil
        }()
        let d = Delivery(
            id: id, hookID: hookID, event: event, url: url,
            attempts: attempts, lastStatus: status, lastError: error,
            deliveredAt: Date(), durationMs: durationMs,
            body: storedBody
        )
        env.deliveries.append(d)
        if env.deliveries.count > deliveryRingSize {
            env.deliveries.removeFirst(env.deliveries.count - deliveryRingSize)
        }
        if let idx = env.hooks.firstIndex(where: { $0.id == hookID }) {
            env.hooks[idx].lastDeliveredAt = d.deliveredAt
            env.hooks[idx].lastStatus = status
        }
        try persist(env, user: user, repo: repo)
    }

    // MARK: - Helpers

    private static func validateURL(_ s: String) throws {
        guard let url = URL(string: s) else {
            throw StoreError.invalidURL(s)
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw StoreError.invalidURL(s) }
        guard url.host?.isEmpty == false else { throw StoreError.invalidURL(s) }
    }

    private static func validateEvents(_ events: [String]) throws -> [String] {
        let trimmed = events.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("at least one event required")
        }
        for e in trimmed {
            if e == "*" { continue }   // wildcard
            guard supportedEvents.contains(e) else {
                throw StoreError.invalidEvent(e)
            }
        }
        // Dedupe preserving order.
        var seen = Set<String>()
        return trimmed.filter { seen.insert($0).inserted }
    }

    /// Phase 23: pattern validation. Glob-ish characters allowed: `*`,
    /// `?`, plus `A-Za-z0-9._/-`. Empty patterns rejected; >64 patterns
    /// rejected (we apply them on every push, no point allowing more).
    private static let allowedPatternChars: Set<Character> = {
        var s: Set<Character> = []
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-*?" { s.insert(c) }
        return s
    }()
    static func validatePatterns(_ patterns: [String]) throws {
        guard patterns.count <= 64 else {
            throw StoreError.invalidInput("too many branch patterns (max 64)")
        }
        for p in patterns {
            guard !p.isEmpty else { throw StoreError.invalidInput("empty branch pattern") }
            guard p.count <= 200 else { throw StoreError.invalidInput("branch pattern too long") }
            for ch in p where !allowedPatternChars.contains(ch) {
                throw StoreError.invalidInput("branch pattern '\(p)' contains invalid character '\(ch)'")
            }
        }
    }

    /// Phase 23: glob match with `*` (zero+ chars) and `?` (exactly
    /// one char). Recursive backtracking implementation -- patterns
    /// and refs are short and bounded, so the worst case is fine.
    static func globMatch(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        func helper(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == n.count }
            if p[i] == "*" {
                // Skip consecutive stars.
                var ni = i
                while ni < p.count && p[ni] == "*" { ni += 1 }
                if ni == p.count { return true }
                for k in j...n.count {
                    if helper(ni, k) { return true }
                }
                return false
            }
            if j == n.count { return false }
            if p[i] == "?" || p[i] == n[j] {
                return helper(i + 1, j + 1)
            }
            return false
        }
        return helper(0, 0)
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
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let env = try decoder.decode(Envelope.self, from: data)
                envelopes[key] = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(
            version: 1, nextHookID: 1, nextDeliveryID: 1,
            hooks: [], deliveries: []
        )
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
            .appendingPathComponent("webhooks.json")
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(env)
        } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("webhooks.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

// MARK: - Event sink + dispatcher

/// What the other stores call when something interesting happens.
/// Decouples them from Vapor / Crypto / HTTP wiring.
protocol EventSink: Sendable {
    func fire(user: String, repo: String, event: String, payload: [String: Any]) async
}

/// Background fan-out from event -> matching subscribers.
/// Owns the Vapor `Application` so it can use `app.client.post(...)`
/// to send the actual HTTP POST.
struct WebhookDispatcher: EventSink {
    let store: WebhookStore
    let app: Application

    /// Retry schedule (in seconds): 1, 4, 16. Max 3 attempts total
    /// (the first call + 2 retries).
    private static let retryDelaysSec: [UInt64] = [1, 4, 16]

    func fire(user: String, repo: String, event: String, payload: [String: Any]) async {
        // Look up subscribers off-thread. Errors here (missing repo
        // store, etc.) are swallowed by design -- event firing is
        // best-effort and must NOT crash whatever caused the event.
        let hooks: [WebhookStore.Hook]
        do {
            hooks = try await store.subscribers(user: user, repo: repo, event: event)
        } catch {
            app.logger.warning("[webhook] subscribers lookup failed for \(user)/\(repo) event=\(event): \(error)")
            return
        }
        guard !hooks.isEmpty else { return }

        // Phase 23: branch-pattern filter for push events. Extract ref
        // names from refUpdates and short-name them (strip refs/heads/).
        // Hooks without branchPatterns fire unconditionally.
        let pushedBranchNames: [String] = {
            guard event == "push",
                  let refUpdates = payload["refUpdates"] as? [[String: Any]]
            else { return [] }
            return refUpdates.compactMap { upd -> String? in
                guard let ref = upd["ref"] as? String else { return nil }
                let prefix = "refs/heads/"
                if ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
                return ref
            }
        }()

        // Serialise the payload exactly once.
        let body: Data
        do {
            // Augment with event metadata so receivers can route.
            var augmented = payload
            augmented["event"] = event
            augmented["repo"] = "\(user)/\(repo)"
            augmented["deliveredAt"] = ISO8601DateFormatter().string(from: Date())
            body = try JSONSerialization.data(
                withJSONObject: augmented,
                options: [.sortedKeys]
            )
        } catch {
            app.logger.error("[webhook] payload encode failed: \(error)")
            return
        }
        for hook in hooks {
            // Phase 23 filter.
            if event == "push", let patterns = hook.branchPatterns, !patterns.isEmpty {
                let anyMatch = pushedBranchNames.contains { name in
                    patterns.contains { WebhookStore.globMatch(pattern: $0, name: name) }
                }
                if !anyMatch {
                    app.logger.debug("[webhook] hook#\(hook.id) push event filtered out by branchPatterns")
                    continue
                }
            }
            // Phase 24 rate limit: per-hook recent-attempt counter.
            if let limit = hook.rateLimitPerMinute, limit > 0 {
                let dropped = await Self.acquireRateLimitSlot(hook: hook, limitPerMinute: limit)
                if dropped {
                    app.logger.warning("[webhook] hook#\(hook.id) DROPPED (rate-limited at \(limit)/min)")
                    let url = hook.url
                    let hookID = hook.id
                    let store = self.store
                    let app = self.app
                    Task {
                        try? await store.recordDelivery(
                            user: user, repo: repo,
                            hookID: hookID, event: event, url: url,
                            attempts: 0, status: nil,
                            error: "rate-limited (cap \(limit)/min)",
                            durationMs: 0, body: nil
                        )
                        _ = app
                    }
                    continue
                }
            }
            // Each hook gets its own Task -- one slow receiver shouldn't
            // block delivery to others.
            let store = self.store
            let app = self.app
            Task {
                await Self.deliver(hook: hook,
                                   user: user, repo: repo,
                                   event: event, body: body,
                                   store: store, app: app)
            }
        }
    }

    // MARK: Phase 24 rate-limit bookkeeping
    //
    // Each (user, repo, hookID) gets a tiny in-memory ring of attempt
    // timestamps. acquireRateLimitSlot returns true when the call should
    // be dropped (cap exceeded in the last 60 seconds); false otherwise
    // (and records the new attempt). State is best-effort and lost on
    // restart; that's fine for an anti-abuse signal.
    private actor RateLimiter {
        var attempts: [Int: [Date]] = [:]
        func recordAndCheck(hookID: Int, limit: Int) -> Bool {
            let now = Date()
            let cutoff = now.addingTimeInterval(-60)
            var list = (attempts[hookID] ?? []).filter { $0 > cutoff }
            if list.count >= limit {
                attempts[hookID] = list
                return true   // drop
            }
            list.append(now)
            attempts[hookID] = list
            return false      // allow
        }
    }
    private static let rateLimiter = RateLimiter()

    private static func acquireRateLimitSlot(hook: WebhookStore.Hook, limitPerMinute: Int) async -> Bool {
        await rateLimiter.recordAndCheck(hookID: hook.id, limit: limitPerMinute)
    }

    /// Single-hook delivery loop with bounded retries.
    private static func deliver(
        hook: WebhookStore.Hook,
        user: String, repo: String,
        event: String, body: Data,
        store: WebhookStore, app: Application
    ) async {
        let started = Date()
        var attempts = 0
        var lastStatus: Int? = nil
        var lastError: String? = nil
        // Pre-compute the HMAC signature once.
        let signature: String? = {
            guard let secret = hook.secret, !secret.isEmpty else { return nil }
            let key = SymmetricKey(data: Data(secret.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
            return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        }()
        let uri = URI(string: hook.url)
        attemptLoop: for attempt in 0..<Self.retryDelaysSec.count {
            if attempt > 0 {
                // Backoff before retry.
                try? await Task.sleep(nanoseconds: Self.retryDelaysSec[attempt] * 1_000_000_000)
            }
            attempts = attempt + 1
            do {
                let response = try await app.client.post(uri) { req in
                    req.headers.replaceOrAdd(name: .contentType,
                                             value: "application/json; charset=utf-8")
                    req.headers.replaceOrAdd(name: "User-Agent",
                                             value: "giteax-webhooks/0.0.10")
                    req.headers.replaceOrAdd(name: "X-Giteax-Event", value: event)
                    req.headers.replaceOrAdd(name: "X-Giteax-Delivery", value: UUID().uuidString)
                    if let signature {
                        req.headers.replaceOrAdd(name: "X-Giteax-Signature",
                                                 value: signature)
                    }
                    req.body = ByteBuffer(data: body)
                }
                lastStatus = Int(response.status.code)
                lastError = nil
                if (200...299).contains(response.status.code) {
                    break attemptLoop  // success
                }
                // Non-2xx => retry.
                lastError = "HTTP \(response.status.code)"
            } catch {
                lastStatus = nil
                lastError = "transport: \(error)"
            }
        }
        let duration = Int(Date().timeIntervalSince(started) * 1000)
        do {
            try await store.recordDelivery(
                user: user, repo: repo,
                hookID: hook.id, event: event, url: hook.url,
                attempts: attempts,
                status: lastStatus,
                error: lastError,
                durationMs: duration,
                body: body
            )
        } catch {
            app.logger.warning("[webhook] recordDelivery failed for hook=\(hook.id): \(error)")
        }
        if let lastError {
            app.logger.warning(
                "[webhook] \(user)/\(repo) hook#\(hook.id) event=\(event) attempts=\(attempts) status=\(lastStatus.map(String.init) ?? "-") error=\(lastError)"
            )
        } else {
            app.logger.notice(
                "[webhook] \(user)/\(repo) hook#\(hook.id) event=\(event) attempts=\(attempts) status=\(lastStatus.map(String.init) ?? "-") (\(duration) ms)"
            )
        }
    }

    /// Phase 21: replay a single hook with a pre-encoded payload body.
    /// Used by the redeliver endpoint when the original delivery's body
    /// was persisted (<= 64 KiB). Fires asynchronously like `fire`.
    func deliverOne(
        hook: WebhookStore.Hook,
        user: String, repo: String,
        event: String, body: Data
    ) {
        let store = self.store
        let app = self.app
        Task {
            await Self.deliver(
                hook: hook,
                user: user, repo: repo,
                event: event, body: body,
                store: store, app: app
            )
        }
    }
}

/// No-op sink for when the dispatcher isn't wired up (shouldn't happen
/// in normal startup but keeps the protocol non-optional in callers).
struct DiscardEventSink: EventSink {
    func fire(user: String, repo: String, event: String, payload: [String: Any]) async {
        // Discard.
    }
}
