import Foundation
import Crypto
import Vapor

/// Phase 39: Gitea Actions-style runner registry (global).
///
/// On-disk shape (one envelope, server-wide):
///
///     <root>/.giteax/runners.json
///       {
///         "version": 1,
///         "nextID": 5,
///         "runners": [
///           { id, name, tokenHash, labels[], registeredBy, createdAt, lastSeenAt? }
///         ]
///       }
///
/// `tokenHash` is SHA-256(plaintext) hex. The plaintext token is
/// returned exactly once on registration (POST /api/admin/runners).
/// Token format: `giteax_runner_` + 32 url-safe base64 chars.
actor RunnerStore {

    static let plaintextPrefix = "giteax_runner_"

    struct Runner: Sendable, Codable {
        let id: Int
        var name: String
        var tokenHash: String
        var labels: [String]
        let registeredBy: String
        let createdAt: Date
        var lastSeenAt: Date?
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextID: Int
        var runners: [Runner]
    }

    enum StoreError: Error, AbortError {
        case invalidInput(String)
        case notFound(Int)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidInput: .badRequest
            case .notFound:     .notFound
            case .ioFailed, .badEnvelope: .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .invalidInput(let d): "invalid runner input: \(d)"
            case .notFound(let id):    "no runner with id=\(id)"
            case .ioFailed(let d):     "runner-store I/O failed: \(d)"
            case .badEnvelope(let d):  "runner-store JSON malformed: \(d)"
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

    func list() throws -> [Runner] {
        let env = try loadOrInit()
        return env.runners.sorted { $0.id < $1.id }
    }

    func get(id: Int) throws -> Runner {
        let env = try loadOrInit()
        guard let r = env.runners.first(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        return r
    }

    /// Returns the runner whose tokenHash matches SHA-256(plaintext),
    /// touching `lastSeenAt` to now. Returns nil for unknown tokens.
    func authenticate(plaintextToken: String) throws -> Runner? {
        guard plaintextToken.hasPrefix(Self.plaintextPrefix) else { return nil }
        let hash = Self.hash(plaintextToken)
        var env = try loadOrInit()
        guard let idx = env.runners.firstIndex(where: { $0.tokenHash == hash }) else { return nil }
        env.runners[idx].lastSeenAt = Date()
        try persist(env)
        return env.runners[idx]
    }

    // MARK: - Mutate

    /// Register a new runner. Returns (Runner, plaintext token) — the
    /// plaintext is shown to the caller exactly once.
    func register(name: String, labels: [String], registeredBy: String) throws -> (Runner, String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            throw StoreError.invalidInput("name must be 1..64 non-blank chars")
        }
        let cleanLabels = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard cleanLabels.count <= 32 else {
            throw StoreError.invalidInput("max 32 labels")
        }
        var env = try loadOrInit()
        let id = env.nextID
        env.nextID += 1
        let plaintext = Self.plaintextPrefix + Self.randomToken(byteCount: 24)
        let runner = Runner(
            id: id, name: trimmedName, tokenHash: Self.hash(plaintext),
            labels: cleanLabels, registeredBy: registeredBy,
            createdAt: Date(), lastSeenAt: nil
        )
        env.runners.append(runner)
        try persist(env)
        return (runner, plaintext)
    }

    @discardableResult
    func delete(id: Int) throws -> Bool {
        var env = try loadOrInit()
        let before = env.runners.count
        env.runners.removeAll { $0.id == id }
        guard env.runners.count != before else { return false }
        try persist(env)
        return true
    }

    // MARK: - Helpers

    private static func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        // url-safe base64 without padding
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(b64.prefix(32))
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
        let env = Envelope(version: 1, nextID: 1, runners: [])
        envelope = env
        return env
    }

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("runners.json")
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
            .appendingPathComponent("runners.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
