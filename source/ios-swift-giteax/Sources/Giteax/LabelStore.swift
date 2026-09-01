import Foundation
import Vapor

/// Phase 42 -- per-repo labels and milestones.
///
/// Two actors in one file because they share lifecycle, on-disk
/// neighborhood, and operational concerns (both write to
/// `<root>/.giteax/repos/<u>/<r>/{labels,milestones}.json` and both
/// validate the parent repo's existence).
///
/// Labels are NAME-keyed metadata (color + description). The
/// already-existing `IssueStore.Issue.labels: [String]` field stores
/// the names; the label entity here lets us paint colors and
/// descriptions on top. Labels are NOT enforced as a foreign key on
/// issue.labels -- an issue can carry a label name that's not in
/// LabelStore, and a label can be deleted while issues still
/// reference its name. This matches Gitea / GitHub behavior and
/// keeps the storage independent.
///
/// Milestones are NUMBER-keyed (auto-incrementing per repo). Issues
/// reference them via the new `IssueStore.Issue.milestone: Int?`
/// field added in Phase 42.

// MARK: - LabelStore

actor LabelStore {

    struct Label: Sendable, Codable {
        var name: String
        var color: String          // 6-digit hex without leading '#', e.g. "ff0000"
        var description: String
        let createdAt: Date
        var updatedAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var labels: [Label]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case notFound(String)
        case alreadyExists(String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound, .notFound: return .notFound
            case .alreadyExists:           return .conflict
            case .invalidInput:            return .badRequest
            case .ioFailed, .badEnvelope:  return .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): return "no repository at \(u)/\(r)"
            case .notFound(let d):            return "label not found: \(d)"
            case .alreadyExists(let d):       return "label already exists: \(d)"
            case .invalidInput(let d):        return "invalid label input: \(d)"
            case .ioFailed(let d):            return "label-store I/O failed: \(d)"
            case .badEnvelope(let d):         return "label-store JSON malformed: \(d)"
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

    /// Phase 44: drop cached envelope for `user/repo`.
    func evictRepo(user: String, repo: String) {
        envelopes.removeValue(forKey: "\(user)/\(repo)")
    }

    func list(user: String, repo: String) throws -> [Label] {
        let env = try loadOrInit(user: user, repo: repo)
        return env.labels.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func get(user: String, repo: String, name: String) throws -> Label {
        let env = try loadOrInit(user: user, repo: repo)
        guard let l = env.labels.first(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        return l
    }

    @discardableResult
    func create(user: String, repo: String, name: String, color: String, description: String) throws -> Label {
        let n = try Self.validateName(name)
        let c = try Self.validateColor(color)
        let d = Self.validateDescription(description)
        var env = try loadOrInit(user: user, repo: repo)
        if env.labels.contains(where: { $0.name == n }) {
            throw StoreError.alreadyExists(n)
        }
        let now = Date()
        let label = Label(name: n, color: c, description: d, createdAt: now, updatedAt: now)
        env.labels.append(label)
        try persist(env, user: user, repo: repo)
        return label
    }

    @discardableResult
    func update(user: String, repo: String, name: String, color: String?, description: String?) throws -> Label {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.labels.firstIndex(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        var label = env.labels[idx]
        if let c = color {
            label.color = try Self.validateColor(c)
        }
        if let d = description {
            label.description = Self.validateDescription(d)
        }
        label.updatedAt = Date()
        env.labels[idx] = label
        try persist(env, user: user, repo: repo)
        return label
    }

    func delete(user: String, repo: String, name: String) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.labels.contains(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        env.labels.removeAll { $0.name == name }
        try persist(env, user: user, repo: repo)
    }

    // MARK: helpers

    private static func validateName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidInput("name is empty") }
        guard trimmed.count <= 80 else { throw StoreError.invalidInput("name must be <= 80 chars") }
        // Disallow slash so the label segment doesn't collide with route parsing.
        guard !trimmed.contains("/") else { throw StoreError.invalidInput("name cannot contain '/'") }
        return trimmed
    }

    private static func validateColor(_ raw: String) throws -> String {
        var c = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("#") { c.removeFirst() }
        guard c.count == 6 else { throw StoreError.invalidInput("color must be 6-digit hex") }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard c.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            throw StoreError.invalidInput("color must be hex digits 0-9a-f")
        }
        return c.lowercased()
    }

    private static func validateDescription(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(512))
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
        let env = Envelope(version: 1, labels: [])
        envelopes[key] = env
        return env
    }

    private func repoExistsOnDisk(user: String, repo: String) -> Bool {
        let bare = root.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("labels.json")
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        envelopes[key] = env
        let url = envelopeURL(user: user, repo: repo)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(env)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("labels.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
            try data.write(to: tmp, options: .atomic)
            // Foundation's `replaceItemAt` is unimplemented on swift-corelibs
            // Windows; remove-then-move is portable.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            throw StoreError.ioFailed(String(describing: error))
        }
    }
}

// MARK: - MilestoneStore

actor MilestoneStore {

    enum State: String, Sendable, Codable, CaseIterable {
        case open
        case closed
    }

    struct Milestone: Sendable, Codable {
        let number: Int
        var title: String
        var description: String
        var dueOn: Date?
        var state: State
        let createdAt: Date
        var updatedAt: Date
        var closedAt: Date?
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextNumber: Int
        var milestones: [Milestone]
    }

    enum StoreError: Error, AbortError {
        case repoNotFound(user: String, repo: String)
        case notFound(Int)
        case alreadyExists(String)
        case invalidInput(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .repoNotFound, .notFound: return .notFound
            case .alreadyExists:           return .conflict
            case .invalidInput:            return .badRequest
            case .ioFailed, .badEnvelope:  return .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .repoNotFound(let u, let r): return "no repository at \(u)/\(r)"
            case .notFound(let n):            return "milestone #\(n) not found"
            case .alreadyExists(let d):       return "milestone title already exists: \(d)"
            case .invalidInput(let d):        return "invalid milestone input: \(d)"
            case .ioFailed(let d):            return "milestone-store I/O failed: \(d)"
            case .badEnvelope(let d):         return "milestone-store JSON malformed: \(d)"
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

    /// Phase 44: drop cached envelope for `user/repo`.
    func evictRepo(user: String, repo: String) {
        envelopes.removeValue(forKey: "\(user)/\(repo)")
    }

    func list(user: String, repo: String, state: State? = nil) throws -> [Milestone] {
        let env = try loadOrInit(user: user, repo: repo)
        var out = env.milestones
        if let state { out = out.filter { $0.state == state } }
        out.sort { $0.number > $1.number }
        return out
    }

    func get(user: String, repo: String, number: Int) throws -> Milestone {
        let env = try loadOrInit(user: user, repo: repo)
        guard let m = env.milestones.first(where: { $0.number == number }) else {
            throw StoreError.notFound(number)
        }
        return m
    }

    /// Used by IssueStore-side validation in IssueRoutes when a caller
    /// references a milestone number on issue create/update.
    func exists(user: String, repo: String, number: Int) async -> Bool {
        guard let env = try? loadOrInit(user: user, repo: repo) else { return false }
        return env.milestones.contains { $0.number == number }
    }

    @discardableResult
    func create(user: String, repo: String, title: String, description: String, dueOn: Date?) throws -> Milestone {
        let t = try Self.validateTitle(title)
        var env = try loadOrInit(user: user, repo: repo)
        if env.milestones.contains(where: { $0.title.lowercased() == t.lowercased() }) {
            throw StoreError.alreadyExists(t)
        }
        let now = Date()
        let number = env.nextNumber
        env.nextNumber += 1
        let m = Milestone(
            number: number, title: t,
            description: Self.validateDescription(description),
            dueOn: dueOn, state: .open,
            createdAt: now, updatedAt: now, closedAt: nil
        )
        env.milestones.append(m)
        try persist(env, user: user, repo: repo)
        return m
    }

    @discardableResult
    func update(
        user: String, repo: String, number: Int,
        title: String?, description: String?, dueOn: Date??, state: State?
    ) throws -> Milestone {
        var env = try loadOrInit(user: user, repo: repo)
        guard let idx = env.milestones.firstIndex(where: { $0.number == number }) else {
            throw StoreError.notFound(number)
        }
        var m = env.milestones[idx]
        if let t = title {
            let trimmed = try Self.validateTitle(t)
            if env.milestones.contains(where: { $0.number != number && $0.title.lowercased() == trimmed.lowercased() }) {
                throw StoreError.alreadyExists(trimmed)
            }
            m.title = trimmed
        }
        if let d = description { m.description = Self.validateDescription(d) }
        // dueOn is double-optional: nil means "leave alone"; .some(nil) means "clear".
        if let dueArg = dueOn {
            m.dueOn = dueArg
        }
        if let s = state {
            if s == .closed && m.state == .open {
                m.closedAt = Date()
            } else if s == .open {
                m.closedAt = nil
            }
            m.state = s
        }
        m.updatedAt = Date()
        env.milestones[idx] = m
        try persist(env, user: user, repo: repo)
        return m
    }

    func delete(user: String, repo: String, number: Int) throws {
        var env = try loadOrInit(user: user, repo: repo)
        guard env.milestones.contains(where: { $0.number == number }) else {
            throw StoreError.notFound(number)
        }
        env.milestones.removeAll { $0.number == number }
        try persist(env, user: user, repo: repo)
    }

    // MARK: helpers

    private static func validateTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidInput("title is empty") }
        guard trimmed.count <= 256 else { throw StoreError.invalidInput("title must be <= 256 chars") }
        return trimmed
    }

    private static func validateDescription(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(4096))
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
        let env = Envelope(version: 1, nextNumber: 1, milestones: [])
        envelopes[key] = env
        return env
    }

    private func repoExistsOnDisk(user: String, repo: String) -> Bool {
        let bare = root.appendingPathComponent(user).appendingPathComponent("\(repo).git")
        if FileManager.default.fileExists(atPath: bare.path) { return true }
        let working = root.appendingPathComponent(user).appendingPathComponent(repo)
        return FileManager.default.fileExists(atPath: working.path)
    }

    private func envelopeURL(user: String, repo: String) -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("milestones.json")
    }

    private func persist(_ env: Envelope, user: String, repo: String) throws {
        let key = "\(user)/\(repo)"
        envelopes[key] = env
        let url = envelopeURL(user: user, repo: repo)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(env)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("milestones.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
