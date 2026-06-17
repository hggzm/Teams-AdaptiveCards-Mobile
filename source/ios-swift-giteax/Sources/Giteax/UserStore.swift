import Foundation
import Vapor

/// Filesystem-backed user store with bcrypt-hashed passwords.
///
/// On-disk shape (`<root>/.giteax/users.json`):
///
///     {
///       "version": 1,
///       "users": [
///         { "name": "alice", "passwordHash": "$2b$...", "createdAt": "...", "isAdmin": false }
///       ]
///     }
///
/// All mutations go through `update(_:)` which performs an atomic
/// write (temp-file + rename). Reads use the in-memory snapshot.
///
/// Auth model is intentionally tiny in v0.0.7:
///   - `verify(name:password:)` is the gate that HTTP Basic auth uses.
///   - `create(...)` / `delete(...)` are admin-only (token from env).
///   - No sessions, no OAuth, no 2FA. Those are explicit Phase 9+ items.
actor UserStore {
    struct User: Sendable, Codable {
        let name: String
        /// bcrypt hash (computed via Vapor's `Bcrypt` helper).
        let passwordHash: String
        let createdAt: Date
        var isAdmin: Bool
    }

    /// JSON envelope on disk. Versioned so we can migrate later.
    private struct Envelope: Sendable, Codable {
        var version: Int
        var users: [User]
    }

    enum StoreError: Error, AbortError {
        case invalidName(String)
        case weakPassword
        case alreadyExists(String)
        case notFound(String)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidName:      .badRequest
            case .weakPassword:     .badRequest
            case .alreadyExists:    .conflict
            case .notFound:         .notFound
            case .ioFailed:         .internalServerError
            case .badEnvelope:      .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .invalidName(let n):
                return "invalid username: '\(n)' (must match [A-Za-z0-9][A-Za-z0-9._-]{0,99})"
            case .weakPassword:
                return "password must be at least 8 characters"
            case .alreadyExists(let n):
                return "user '\(n)' already exists"
            case .notFound(let n):
                return "no such user: '\(n)'"
            case .ioFailed(let d):
                return "user-store I/O failed: \(d)"
            case .badEnvelope(let d):
                return "user-store JSON malformed: \(d)"
            }
        }
    }

    /// Absolute path to the users.json file.
    let storePath: URL
    private var envelope: Envelope

    /// Construct a user store rooted at `<root>/.giteax/users.json`. The
    /// store is loaded synchronously at startup; ANY I/O failure during
    /// the initial load is reported via the throwing init so the server
    /// fails-fast instead of silently running with no users.
    init(root: URL) throws {
        let giteaxDir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(
            at: giteaxDir, withIntermediateDirectories: true
        )
        self.storePath = giteaxDir.appendingPathComponent("users.json")

        if FileManager.default.fileExists(atPath: storePath.path) {
            do {
                let data = try Data(contentsOf: storePath)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.envelope = try decoder.decode(Envelope.self, from: data)
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        } else {
            self.envelope = Envelope(version: 1, users: [])
            try Self.persist(envelope, to: storePath)
        }
    }

    // MARK: - Read

    func count() -> Int { envelope.users.count }

    /// Snapshot of all usernames. Order is insertion order on disk.
    func listNames() -> [String] { envelope.users.map(\.name) }

    /// True iff at least one user exists. Used by the auth middleware
    /// to decide whether to enforce HTTP Basic on push (no users yet ==
    /// fall back to the env-flag gate; anyone with `GITEAX_ALLOW_PUSH=1`
    /// AND `GITEAX_ALLOW_ANON_PUSH=1` set can still push anonymously).
    func isEmpty() -> Bool { envelope.users.isEmpty }

    /// Look up a user by name (case-sensitive, matching git's behavior).
    func get(_ name: String) -> User? {
        envelope.users.first(where: { $0.name == name })
    }

    /// Verify a (name, password) tuple. Returns the User on success.
    func verify(name: String, password: String) -> User? {
        guard let u = get(name) else { return nil }
        let ok = (try? Bcrypt.verify(password, created: u.passwordHash)) ?? false
        return ok ? u : nil
    }

    // MARK: - Mutate

    /// Create a new user. Hashes the password with bcrypt. Cost factor
    /// defaults to Vapor's `Bcrypt`'s default (currently 12) which is
    /// reasonable on modern hardware. Throws on validation, duplicate,
    /// or I/O failure.
    @discardableResult
    func create(name: String, password: String, isAdmin: Bool) throws -> User {
        guard Self.validateName(name) else { throw StoreError.invalidName(name) }
        guard password.count >= 8 else { throw StoreError.weakPassword }
        guard get(name) == nil else { throw StoreError.alreadyExists(name) }
        let hash: String
        do {
            hash = try Bcrypt.hash(password)
        } catch {
            throw StoreError.ioFailed("bcrypt: \(error)")
        }
        let user = User(
            name: name,
            passwordHash: hash,
            createdAt: Date(),
            isAdmin: isAdmin
        )
        envelope.users.append(user)
        try Self.persist(envelope, to: storePath)
        return user
    }

    /// Delete a user. Throws if no such user exists.
    func delete(name: String) throws {
        guard envelope.users.contains(where: { $0.name == name }) else {
            throw StoreError.notFound(name)
        }
        envelope.users.removeAll(where: { $0.name == name })
        try Self.persist(envelope, to: storePath)
    }

    // MARK: - Helpers

    /// Username grammar mirrors the repo-segment validator: must start
    /// with alphanumeric, then allow `.` `_` `-`; total length <= 100.
    static func validateName(_ s: String) -> Bool {
        RepositoryService.validateSegment(s)
    }

    private static func persist(_ env: Envelope, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(env)
        } catch {
            throw StoreError.ioFailed("encode: \(error)")
        }
        // Atomic-ish write via temp + rename. We deliberately don't use
        // `FileManager.replaceItemAt(_:withItemAt:)` -- that API is "not
        // yet implemented" on swift-corelibs-foundation/Windows and would
        // crash the process. Instead: write to a uniquely-named tmp file
        // next to the target, then remove-target + move-into-place. The
        // window between remove and move is small and on a single
        // (filesystem-local) directory rename, so the operation is
        // effectively atomic relative to other writers of THIS file.
        // Other writers in v0.0.7 don't exist (single-process server),
        // so this is sufficient.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("users.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            // Make sure the tmp doesn't linger from a prior crash.
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
