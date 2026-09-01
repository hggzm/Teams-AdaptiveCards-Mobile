import Foundation
import Vapor

/// Phase 36: PR review records (approve / request_changes / comment).
///
/// On-disk shape (sibling of prs.json / issues.json):
///
///     <root>/.giteax/repos/<user>/<repo>/reviews.json
///       {
///         "version": 1,
///         "nextID": 5,
///         "reviews": [
///           { id, prNumber, reviewer, state, body, createdAt }
///         ]
///       }
///
/// "Latest review per (prNumber, reviewer)" wins for approval counting:
/// if alice approves then later requests changes, only the latest
/// counts. The full history is preserved on disk and surfaced by GET.
///
/// The PR-author's own reviews never count towards approvals.
actor PRReviewStore {

    enum State: String, Sendable, Codable, CaseIterable {
        case approved
        case requestedChanges = "requested_changes"
        case commented
    }

    struct Review: Sendable, Codable {
        let id: Int
        let prNumber: Int
        let reviewer: String
        var state: State
        var body: String
        let createdAt: Date
    }

    /// Phase 53: line-anchored comment thread under a Review.
    /// `path` and `line` are optional so a Reviewer can post a plain
    /// reply (whole-PR scope) or anchor to a file/line.
    struct ReviewComment: Sendable, Codable {
        let id: Int
        let reviewID: Int
        let prNumber: Int
        var path: String?
        var line: Int?
        var body: String
        let author: String
        let createdAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextID: Int
        var reviews: [Review]
        // Phase 53 (decode-compat: optional + default).
        var nextCommentID: Int?
        var comments: [ReviewComment]?
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)
        // Phase 53.
        case reviewNotFound(id: Int)
        case commentNotFound(id: Int)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound: .notFound
            case .invalidInput: .badRequest
            case .ioFailed, .badEnvelope: .internalServerError
            case .reviewNotFound, .commentNotFound: .notFound
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): "no repository at \(u)/\(r)"
            case .invalidInput(let d): "invalid review input: \(d)"
            case .ioFailed(let d): "review-store I/O failed: \(d)"
            case .badEnvelope(let d): "review-store JSON malformed: \(d)"
            case .reviewNotFound(let id): "review #\(id) not found"
            case .commentNotFound(let id): "review-comment #\(id) not found"
            }
        }
    }

    let root: URL
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

    func list(user: String, repo: String, prNumber: Int) throws -> [Review] {
        let env = try loadOrInit(user: user, repo: repo)
        return env.reviews.filter { $0.prNumber == prNumber }
            .sorted { $0.id < $1.id }
    }

    /// Returns the set of reviewer names whose latest review per PR is
    /// `approved`, EXCLUDING the PR author. Used by the merge gate.
    func approvers(user: String, repo: String, prNumber: Int, prAuthor: String) throws -> [String] {
        let env = try loadOrInit(user: user, repo: repo)
        // Sort ascending by id so the last write wins per reviewer.
        var latest: [String: State] = [:]
        for r in env.reviews where r.prNumber == prNumber {
            latest[r.reviewer] = r.state
        }
        return latest.compactMap { (name, state) in
            (state == .approved && name != prAuthor) ? name : nil
        }.sorted()
    }

    // MARK: - Mutate

    @discardableResult
    func add(
        user: String, repo: String,
        prNumber: Int, reviewer: String,
        state: State, body: String
    ) throws -> Review {
        guard !reviewer.isEmpty else {
            throw StoreError.invalidInput("reviewer must be non-empty")
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == .commented && trimmed.isEmpty {
            throw StoreError.invalidInput("review body required when state=commented")
        }
        var env = try loadOrInit(user: user, repo: repo)
        let id = env.nextID
        env.nextID += 1
        let review = Review(
            id: id, prNumber: prNumber, reviewer: reviewer,
            state: state, body: body, createdAt: Date()
        )
        env.reviews.append(review)
        try persist(env, user: user, repo: repo)
        return review
    }

    // MARK: - Helpers

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
        let env = Envelope(version: 1, nextID: 1, reviews: [], nextCommentID: 1, comments: [])
        envelopes[key] = env
        return env
    }

    // MARK: - Phase 53: review comments

    func comments(user: String, repo: String, reviewID: Int) throws -> [ReviewComment] {
        let env = try loadOrInit(user: user, repo: repo)
        guard env.reviews.contains(where: { $0.id == reviewID }) else {
            throw StoreError.reviewNotFound(id: reviewID)
        }
        return (env.comments ?? []).filter { $0.reviewID == reviewID }.sorted { $0.id < $1.id }
    }

    @discardableResult
    func addComment(
        user: String, repo: String,
        reviewID: Int, author: String,
        path: String?, line: Int?, body: String
    ) throws -> ReviewComment {
        guard !author.isEmpty else {
            throw StoreError.invalidInput("author must be non-empty")
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("comment body is empty")
        }
        if let l = line, l < 1 {
            throw StoreError.invalidInput("line must be >= 1")
        }
        var env = try loadOrInit(user: user, repo: repo)
        guard let review = env.reviews.first(where: { $0.id == reviewID }) else {
            throw StoreError.reviewNotFound(id: reviewID)
        }
        var next = env.nextCommentID ?? 1
        let id = next
        next += 1
        env.nextCommentID = next
        let c = ReviewComment(
            id: id, reviewID: reviewID, prNumber: review.prNumber,
            path: path, line: line, body: body, author: author,
            createdAt: Date()
        )
        var comments = env.comments ?? []
        comments.append(c)
        env.comments = comments
        try persist(env, user: user, repo: repo)
        return c
    }

    @discardableResult
    func removeComment(
        user: String, repo: String,
        reviewID: Int, commentID: Int
    ) throws -> ReviewComment {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.reviews.contains(where: { $0.id == reviewID }) else {
            throw StoreError.reviewNotFound(id: reviewID)
        }
        var comments = env.comments ?? []
        guard let idx = comments.firstIndex(where: { $0.id == commentID && $0.reviewID == reviewID }) else {
            throw StoreError.commentNotFound(id: commentID)
        }
        let removed = comments.remove(at: idx)
        env.comments = comments
        try persist(env, user: user, repo: repo)
        return removed
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
            .appendingPathComponent("reviews.json")
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
            .appendingPathComponent("reviews.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
