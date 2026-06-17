import Foundation
import Vapor

/// Phase 39: Gitea Actions-style job queue.
///
/// On-disk shape (one envelope, server-wide):
///
///     <root>/.giteax/jobs.json
///       {
///         "version": 1,
///         "nextID": 5,
///         "jobs": [
///           { id, repoUser, repoName, workflow, ref, payload?,
///             state, runnerID?, requestedBy,
///             createdAt, startedAt?, finishedAt?, exitCode?, output? }
///         ]
///       }
///
/// State machine:
///
///     queued ─claim→ running ─report(success|failure)→ terminal
///        └─────────cancel─────────┘
///
/// `claimNext` picks the oldest queued job whose required labels are
/// a subset of the runner's labels. (No labels on a job means any
/// runner accepts it.)
actor JobStore {

    enum State: String, Sendable, Codable, CaseIterable {
        case queued, running, success, failure, cancelled
    }

    struct Job: Sendable, Codable {
        let id: Int
        let repoUser: String
        let repoName: String
        var workflow: String
        var ref: String
        var payload: String?
        var labels: [String]
        var state: State
        var runnerID: Int?
        let requestedBy: String
        let createdAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var exitCode: Int?
        var output: String?
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextID: Int
        var jobs: [Job]
    }

    enum StoreError: Error, AbortError {
        case invalidInput(String)
        case notFound(Int)
        case wrongState(Int, current: State, expected: String)
        case wrongRunner(Int)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidInput: .badRequest
            case .notFound:     .notFound
            case .wrongState:   .conflict
            case .wrongRunner:  .forbidden
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .invalidInput(let d): "invalid job input: \(d)"
            case .notFound(let id):    "no job with id=\(id)"
            case .wrongState(let id, let cur, let exp): "job \(id) is in state '\(cur.rawValue)', expected \(exp)"
            case .wrongRunner(let id): "job \(id) is owned by a different runner"
            case .ioFailed(let d):     "job-store I/O failed: \(d)"
            case .badEnvelope(let d):  "job-store JSON malformed: \(d)"
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

    // MARK: - Read

    func list(user: String, repo: String, stateFilter: State? = nil) throws -> [Job] {
        let env = try loadOrInit()
        return env.jobs
            .filter { $0.repoUser == user && $0.repoName == repo }
            .filter { stateFilter == nil || $0.state == stateFilter }
            .sorted { $0.id < $1.id }
    }

    func get(id: Int) throws -> Job {
        let env = try loadOrInit()
        guard let j = env.jobs.first(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        return j
    }

    // MARK: - Mutate

    func enqueue(
        user: String, repo: String,
        workflow: String, ref: String, payload: String?,
        labels: [String], requestedBy: String
    ) throws -> Job {
        let trimmedWf = workflow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWf.isEmpty, trimmedWf.count <= 128 else {
            throw StoreError.invalidInput("workflow must be 1..128 non-blank chars")
        }
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty, trimmedRef.count <= 256 else {
            throw StoreError.invalidInput("ref must be 1..256 non-blank chars")
        }
        if let p = payload, p.utf8.count > 64 * 1024 {
            throw StoreError.invalidInput("payload exceeds 64 KiB")
        }
        let cleanLabels = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var env = try loadOrInit()
        let id = env.nextID
        env.nextID += 1
        let job = Job(
            id: id, repoUser: user, repoName: repo,
            workflow: trimmedWf, ref: trimmedRef, payload: payload,
            labels: cleanLabels, state: .queued, runnerID: nil,
            requestedBy: requestedBy, createdAt: Date(),
            startedAt: nil, finishedAt: nil, exitCode: nil, output: nil
        )
        env.jobs.append(job)
        try persist(env)
        return job
    }

    /// Pick the oldest queued job whose required labels are a subset
    /// of the runner's labels. Atomically transitions state to
    /// `.running` and stamps `runnerID` + `startedAt`. Returns nil if
    /// no eligible job is queued.
    func claimNext(runnerID: Int, runnerLabels: [String]) throws -> Job? {
        var env = try loadOrInit()
        let runnerSet = Set(runnerLabels)
        guard let idx = env.jobs.firstIndex(where: { j in
            guard j.state == .queued else { return false }
            return Set(j.labels).isSubset(of: runnerSet)
        }) else { return nil }
        env.jobs[idx].state = .running
        env.jobs[idx].runnerID = runnerID
        env.jobs[idx].startedAt = Date()
        try persist(env)
        return env.jobs[idx]
    }

    /// Runner reports a final state for a job it claimed. Only the
    /// owning runner may report, and only `running` jobs can transition.
    func report(
        id: Int, runnerID: Int,
        state: State, output: String?, exitCode: Int?
    ) throws -> Job {
        guard state == .success || state == .failure else {
            throw StoreError.invalidInput("report state must be success|failure")
        }
        var env = try loadOrInit()
        guard let idx = env.jobs.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        let cur = env.jobs[idx]
        guard cur.state == .running else {
            throw StoreError.wrongState(id, current: cur.state, expected: "running")
        }
        guard cur.runnerID == runnerID else {
            throw StoreError.wrongRunner(id)
        }
        if let out = output, out.utf8.count > 256 * 1024 {
            throw StoreError.invalidInput("output exceeds 256 KiB")
        }
        env.jobs[idx].state = state
        env.jobs[idx].finishedAt = Date()
        env.jobs[idx].output = output
        env.jobs[idx].exitCode = exitCode
        try persist(env)
        return env.jobs[idx]
    }

    /// Cancel a queued or running job. Idempotent on already-cancelled.
    func cancel(id: Int) throws -> Job {
        var env = try loadOrInit()
        guard let idx = env.jobs.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        let cur = env.jobs[idx].state
        guard cur == .queued || cur == .running else {
            throw StoreError.wrongState(id, current: cur, expected: "queued|running")
        }
        env.jobs[idx].state = .cancelled
        env.jobs[idx].finishedAt = Date()
        try persist(env)
        return env.jobs[idx]
    }

    // MARK: - Helpers

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
        let env = Envelope(version: 1, nextID: 1, jobs: [])
        envelope = env
        return env
    }

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("jobs.json")
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
            .appendingPathComponent("jobs.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
