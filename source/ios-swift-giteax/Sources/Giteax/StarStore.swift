import Foundation
import Vapor

/// Phase 43 -- stars, watches, activity feed.
///
/// Three small actors share this file because they're operationally
/// related: stars and watches are global, single-envelope rows
/// keyed by (user, repo); activity is per-repo, bounded to the last
/// N entries; and the feed is a derived merge over the two.
///
/// On-disk:
///
///     <root>/.giteax/stars.json
///     <root>/.giteax/watches.json
///     <root>/.giteax/repos/<u>/<r>/activity.json
///
/// All three use the portable remove-then-move persist pattern
/// because `FileManager.replaceItemAt` is unimplemented on
/// swift-corelibs Foundation (Windows).

// MARK: - StarStore

actor StarStore {

    struct Star: Sendable, Codable, Hashable {
        let owner: String      // who starred
        let repoOwner: String  // target repo owner
        let repoName: String   // target repo name
        let createdAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var stars: [Star]
    }

    enum StoreError: Error, AbortError {
        case alreadyExists
        case notFound
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .alreadyExists:           return .conflict
            case .notFound:                return .notFound
            case .invalidInput:            return .badRequest
            case .ioFailed, .badEnvelope:  return .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .alreadyExists:       return "already starred"
            case .notFound:            return "not starred"
            case .invalidInput(let d): return "invalid star input: \(d)"
            case .ioFailed(let d):     return "star-store I/O failed: \(d)"
            case .badEnvelope(let d):  return "star-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    private var envelope: Envelope?

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = root
    }

    func isStarred(by user: String, repoOwner: String, repoName: String) throws -> Bool {
        let env = try loadOrInit()
        return env.stars.contains {
            $0.owner == user && $0.repoOwner == repoOwner && $0.repoName == repoName
        }
    }

    func stargazers(repoOwner: String, repoName: String) throws -> [Star] {
        let env = try loadOrInit()
        return env.stars
            .filter { $0.repoOwner == repoOwner && $0.repoName == repoName }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func starredBy(user: String) throws -> [Star] {
        let env = try loadOrInit()
        return env.stars
            .filter { $0.owner == user }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func count(repoOwner: String, repoName: String) throws -> Int {
        try stargazers(repoOwner: repoOwner, repoName: repoName).count
    }

    @discardableResult
    func star(by user: String, repoOwner: String, repoName: String) throws -> Star {
        try validate(user: user, repoOwner: repoOwner, repoName: repoName)
        var env = try loadOrInit()
        if env.stars.contains(where: {
            $0.owner == user && $0.repoOwner == repoOwner && $0.repoName == repoName
        }) {
            throw StoreError.alreadyExists
        }
        let s = Star(owner: user, repoOwner: repoOwner, repoName: repoName, createdAt: Date())
        env.stars.append(s)
        try persist(env)
        return s
    }

    func unstar(by user: String, repoOwner: String, repoName: String) throws {
        var env = try loadOrInit()
        let before = env.stars.count
        env.stars.removeAll {
            $0.owner == user && $0.repoOwner == repoOwner && $0.repoName == repoName
        }
        guard env.stars.count != before else { throw StoreError.notFound }
        try persist(env)
    }

    /// Phase 44: rewrite all rows targeting `(oldOwner, oldRepo)` so
    /// they now target `(newOwner, newRepo)`. Used by repo transfer +
    /// rename. Returns the number of rows touched.
    @discardableResult
    func rewriteRepoRef(oldOwner: String, oldRepo: String, newOwner: String, newRepo: String) throws -> Int {
        if oldOwner == newOwner && oldRepo == newRepo { return 0 }
        var env = try loadOrInit()
        var touched = 0
        for i in env.stars.indices {
            let s = env.stars[i]
            if s.repoOwner == oldOwner && s.repoName == oldRepo {
                env.stars[i] = Star(owner: s.owner, repoOwner: newOwner, repoName: newRepo, createdAt: s.createdAt)
                touched += 1
            }
        }
        if touched > 0 { try persist(env) }
        return touched
    }

    private func validate(user: String, repoOwner: String, repoName: String) throws {
        guard RepositoryService.validateSegment(user),
              RepositoryService.validateSegment(repoOwner),
              RepositoryService.validateSegment(repoName)
        else { throw StoreError.invalidInput("invalid owner/repo segment") }
    }

    private func loadOrInit() throws -> Envelope {
        if let cached = envelope { return cached }
        let url = envelopeURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let env = try dec.decode(Envelope.self, from: data)
                envelope = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(version: 1, stars: [])
        envelope = env
        return env
    }

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("stars.json")
    }

    private func persist(_ env: Envelope) throws {
        envelope = env
        let url = envelopeURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("stars.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

// MARK: - WatchStore

actor WatchStore {

    struct Watch: Sendable, Codable, Hashable {
        let owner: String
        let repoOwner: String
        let repoName: String
        let createdAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var watches: [Watch]
    }

    enum StoreError: Error, AbortError {
        case alreadyExists
        case notFound
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .alreadyExists:           return .conflict
            case .notFound:                return .notFound
            case .invalidInput:            return .badRequest
            case .ioFailed, .badEnvelope:  return .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .alreadyExists:       return "already watching"
            case .notFound:            return "not watching"
            case .invalidInput(let d): return "invalid watch input: \(d)"
            case .ioFailed(let d):     return "watch-store I/O failed: \(d)"
            case .badEnvelope(let d):  return "watch-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    private var envelope: Envelope?

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = root
    }

    func isWatching(_ user: String, repoOwner: String, repoName: String) throws -> Bool {
        let env = try loadOrInit()
        return env.watches.contains {
            $0.owner == user && $0.repoOwner == repoOwner && $0.repoName == repoName
        }
    }

    func watchers(repoOwner: String, repoName: String) throws -> [Watch] {
        let env = try loadOrInit()
        return env.watches
            .filter { $0.repoOwner == repoOwner && $0.repoName == repoName }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func watchedBy(user: String) throws -> [Watch] {
        let env = try loadOrInit()
        return env.watches
            .filter { $0.owner == user }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func watch(by user: String, repoOwner: String, repoName: String) throws -> Watch {
        guard RepositoryService.validateSegment(user),
              RepositoryService.validateSegment(repoOwner),
              RepositoryService.validateSegment(repoName)
        else { throw StoreError.invalidInput("invalid owner/repo segment") }
        var env = try loadOrInit()
        if env.watches.contains(where: {
            $0.owner == user && $0.repoOwner == repoOwner && $0.repoName == repoName
        }) {
            throw StoreError.alreadyExists
        }
        let w = Watch(owner: user, repoOwner: repoOwner, repoName: repoName, createdAt: Date())
        env.watches.append(w)
        try persist(env)
        return w
    }

    func unwatch(by user: String, repoOwner: String, repoName: String) throws {
        var env = try loadOrInit()
        let before = env.watches.count
        env.watches.removeAll {
            $0.owner == user && $0.repoOwner == repoOwner && $0.repoName == repoName
        }
        guard env.watches.count != before else { throw StoreError.notFound }
        try persist(env)
    }

    /// Phase 44: rewrite all rows targeting `(oldOwner, oldRepo)` so
    /// they now target `(newOwner, newRepo)`. Returns rows touched.
    @discardableResult
    func rewriteRepoRef(oldOwner: String, oldRepo: String, newOwner: String, newRepo: String) throws -> Int {
        if oldOwner == newOwner && oldRepo == newRepo { return 0 }
        var env = try loadOrInit()
        var touched = 0
        for i in env.watches.indices {
            let w = env.watches[i]
            if w.repoOwner == oldOwner && w.repoName == oldRepo {
                env.watches[i] = Watch(owner: w.owner, repoOwner: newOwner, repoName: newRepo, createdAt: w.createdAt)
                touched += 1
            }
        }
        if touched > 0 { try persist(env) }
        return touched
    }

    private func loadOrInit() throws -> Envelope {
        if let cached = envelope { return cached }
        let url = envelopeURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let env = try dec.decode(Envelope.self, from: data)
                envelope = env
                return env
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        }
        let env = Envelope(version: 1, watches: [])
        envelope = env
        return env
    }

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("watches.json")
    }

    private func persist(_ env: Envelope) throws {
        envelope = env
        let url = envelopeURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("watches.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

// MARK: - ActivityStore

/// Per-repo bounded activity log. Each repo keeps its last
/// `maxEntriesPerRepo` events. Higher-level routes call `record(...)`
/// either directly (e.g. star/unstar) or indirectly via the
/// `ActivityEventSink` wrapper around `EventSink`.
actor ActivityStore {

    /// Hard cap per repo. We never need more than this; the feed
    /// pages from the latest entries.
    static let maxEntriesPerRepo = 200

    struct Entry: Sendable, Codable {
        let id: Int
        let event: String      // "push", "issue", "pull_request", "star", "watch", ...
        let actor: String?     // login of the actor, if known
        let summary: String    // short freeform line for human display
        let createdAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextId: Int
        var entries: [Entry]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound:            return .notFound
            case .ioFailed, .badEnvelope:  return .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): return "no repository at \(u)/\(r)"
            case .ioFailed(let d):            return "activity-store I/O failed: \(d)"
            case .badEnvelope(let d):         return "activity-store JSON malformed: \(d)"
            }
        }
    }

    let root: URL
    private var envelopes: [String: Envelope] = [:]

    init(root: URL) throws {
        let dir = root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = root
    }

    /// Record an entry. Silently no-ops if the target repo doesn't
    /// exist on disk -- activity is best-effort and must not crash
    /// upstream callers. Returns true if recorded.
    @discardableResult
    func record(
        user: String, repo: String,
        event: String, actor: String?, summary: String
    ) -> Bool {
        guard repoExistsOnDisk(user: user, repo: repo) else { return false }
        do {
            var env = try loadOrInit(user: user, repo: repo)
            let entry = Entry(
                id: env.nextId,
                event: event,
                actor: actor,
                summary: String(summary.prefix(512)),
                createdAt: Date()
            )
            env.nextId += 1
            env.entries.append(entry)
            // Trim to the bound -- keep newest by id.
            if env.entries.count > Self.maxEntriesPerRepo {
                env.entries = Array(env.entries.suffix(Self.maxEntriesPerRepo))
            }
            try persist(env, user: user, repo: repo)
            return true
        } catch {
            return false
        }
    }

    /// Newest-first list of activity entries for one repo, optionally
    /// limited. Returns [] for non-existent repos.
    func list(user: String, repo: String, limit: Int = 50) -> [Entry] {
        guard repoExistsOnDisk(user: user, repo: repo) else { return [] }
        do {
            let env = try loadOrInit(user: user, repo: repo)
            let sorted = env.entries.sorted { $0.createdAt > $1.createdAt }
            return Array(sorted.prefix(max(0, limit)))
        } catch {
            return []
        }
    }

    // MARK: helpers

    private func repoExistsOnDisk(user: String, repo: String) -> Bool {
        let bare = root.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    private func loadOrInit(user: String, repo: String) throws -> Envelope {
        let key = "\(user)/\(repo)"
        if let cached = envelopes[key] { return cached }
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
        let env = Envelope(version: 1, nextId: 1, entries: [])
        envelopes[key] = env
        return env
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("activity.json")
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        envelopes[key] = env
        let url = envelopeURL(user: user, repo: repo)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(env)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("activity.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.removeItem(at: tmp)
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            throw StoreError.ioFailed(String(describing: error))
        }
    }
}

// MARK: - ActivityEventSink + composite

/// EventSink that mirrors webhook fan-out into the per-repo activity
/// log. Extracts a human-friendly summary from common payload shapes.
struct ActivityEventSink: EventSink {
    let store: ActivityStore

    func fire(user: String, repo: String, event: String, payload: [String: Any]) async {
        let actorName = Self.extractActor(payload)
        let summary   = Self.summarize(event: event, payload: payload)
        _ = await store.record(
            user: user, repo: repo,
            event: event, actor: actorName, summary: summary
        )
    }

    private static func extractActor(_ payload: [String: Any]) -> String? {
        // Common shapes in the existing event payloads.
        if let s = payload["actor"] as? String, !s.isEmpty { return s }
        if let s = payload["pusher"] as? String, !s.isEmpty { return s }
        if let s = payload["author"] as? String, !s.isEmpty { return s }
        if let s = payload["by"] as? String, !s.isEmpty { return s }
        if let s = payload["reviewer"] as? String, !s.isEmpty { return s }
        return nil
    }

    private static func summarize(event: String, payload: [String: Any]) -> String {
        switch event {
        case "push":
            if let refs = payload["refUpdates"] as? [[String: Any]], let first = refs.first,
               let ref = first["ref"] as? String {
                return "pushed to \(ref)"
            }
            return "pushed"
        case "issue":
            let action = (payload["action"] as? String) ?? "updated"
            let num    = (payload["number"] as? Int).map { "#\($0)" } ?? ""
            return "\(action) issue \(num)".trimmingCharacters(in: .whitespaces)
        case "issue_comment":
            let num = (payload["number"] as? Int).map { "#\($0)" } ?? ""
            return "commented on issue \(num)".trimmingCharacters(in: .whitespaces)
        case "pull_request":
            let action = (payload["action"] as? String) ?? "updated"
            let num    = (payload["number"] as? Int).map { "#\($0)" } ?? ""
            return "\(action) PR \(num)".trimmingCharacters(in: .whitespaces)
        case "pull_request_comment":
            let num = (payload["number"] as? Int).map { "#\($0)" } ?? ""
            return "commented on PR \(num)".trimmingCharacters(in: .whitespaces)
        case "pull_request_review":
            let num = (payload["number"] as? Int).map { "#\($0)" } ?? ""
            let s   = (payload["state"] as? String) ?? "reviewed"
            return "\(s) PR \(num)".trimmingCharacters(in: .whitespaces)
        case "workflow_run":
            let s = (payload["status"] as? String) ?? "workflow run"
            return "workflow_run: \(s)"
        case "ping":
            return "ping"
        default:
            return event
        }
    }
}

/// Composite EventSink that fans `fire` to every contained sink.
struct CompositeEventSink: EventSink {
    let sinks: [any EventSink]

    init(_ sinks: [any EventSink]) {
        self.sinks = sinks
    }

    func fire(user: String, repo: String, event: String, payload: [String: Any]) async {
        for s in sinks {
            await s.fire(user: user, repo: repo, event: event, payload: payload)
        }
    }
}
