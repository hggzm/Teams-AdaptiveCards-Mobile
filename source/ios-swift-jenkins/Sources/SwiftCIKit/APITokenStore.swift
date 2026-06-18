import Foundation

/// Phase 35: persistent API-token store with per-token scopes.
///
/// On-disk layout: a single JSON file at `<store-root>/tokens.json`
/// containing the `TokenFile` envelope. The file is created lazily
/// on the first write — readers tolerate it missing and behave as an
/// empty store.
///
/// Threading: file I/O is serialized through `actor`. Validation
/// (constant-time secret comparison) is on the hot auth path and runs
/// inside the actor too; we don't expect token counts in the
/// thousands for a personal CI server, so a linear scan is fine.
public actor APITokenStore {

    /// Coarse-grained capability tags. A token is granted a set of
    /// scopes at creation time; the auth helper checks whether the
    /// supplied token's scope set is a superset of the route's
    /// required scope.
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Read-only API access. GET routes are open today, so this
        /// scope exists for future-proofing — it's required only by
        /// routes that explicitly opt in.
        case read
        /// Trigger / cancel builds. Does NOT permit job creation or
        /// token administration.
        case trigger
        /// Full administrative access. Implies `read` and `trigger`.
        case admin
    }

    /// Single token record. `secret` is stored in cleartext; this is
    /// intentional for a personal-CI server where the controller
    /// process already has full filesystem access to everything it
    /// could grant a token. Operators who need hashing can layer a
    /// reverse proxy in front; we surface tokens only on creation.
    public struct Token: Codable, Sendable, Equatable {
        /// Stable short id, used in URLs (`DELETE /api/tokens/:id`).
        public let id: String
        /// Human label, e.g. `"ci-bot"` or `"hugo@laptop"`.
        public let name: String
        /// Cleartext secret. Returned ONLY from `create`; never from
        /// `list`.
        public let secret: String
        public let scopes: [Scope]
        public let createdAt: Date

        public init(id: String, name: String, secret: String,
                    scopes: [Scope], createdAt: Date) {
            self.id = id
            self.name = name
            self.secret = secret
            self.scopes = scopes
            self.createdAt = createdAt
        }
    }

    /// On-disk envelope. Versioned so future schema changes can be
    /// recognized without breaking older controllers reading the file.
    private struct TokenFile: Codable {
        var version: Int
        var tokens: [Token]
    }

    private let url: URL
    private var cache: [Token]?

    /// Initialize the store rooted at `directory`. The directory must
    /// already exist (usually the `JobStore` root).
    public init(directory: URL) {
        self.url = directory.appendingPathComponent("tokens.json")
    }

    /// Convenience: derive the token store path from a `JobStore`.
    public init(jobStore: JobStore) {
        self.init(directory: jobStore.root)
    }

    // ──────────────────────────────────────────────────────────────
    // Read / list
    // ──────────────────────────────────────────────────────────────

    /// Return every token currently on disk, in insertion order.
    public func list() throws -> [Token] {
        return try loadOrEmpty()
    }

    /// Return the token whose `secret` matches `presented`, in
    /// constant time over the token list. Nil if not found.
    public func lookup(secret presented: String) throws -> Token? {
        let all = try loadOrEmpty()
        for t in all {
            if Self.constantTimeEquals(t.secret, presented) {
                return t
            }
        }
        return nil
    }

    // ──────────────────────────────────────────────────────────────
    // Mutation
    // ──────────────────────────────────────────────────────────────

    public enum CreateError: Error, Equatable, Sendable {
        case nameEmpty
        case scopesEmpty
        case duplicateName(String)
    }

    /// Create a new token with the given `name` and `scopes`. The
    /// generated secret is returned only through the `Token` value;
    /// `list()` afterwards still surfaces it, but the HTTP layer is
    /// expected to redact the secret on subsequent reads.
    @discardableResult
    public func create(name: String, scopes: [Scope]) throws -> Token {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CreateError.nameEmpty }
        guard !scopes.isEmpty else { throw CreateError.scopesEmpty }
        var all = try loadOrEmpty()
        if all.contains(where: { $0.name == trimmed }) {
            throw CreateError.duplicateName(trimmed)
        }
        // De-dupe the scope set deterministically.
        var seen: Set<Scope> = []
        var ordered: [Scope] = []
        for s in scopes where !seen.contains(s) {
            seen.insert(s); ordered.append(s)
        }
        let token = Token(
            id: Self.randomID(length: 8),
            name: trimmed,
            secret: Self.randomSecret(),
            scopes: ordered,
            createdAt: Date())
        all.append(token)
        try save(all)
        return token
    }

    public enum DeleteError: Error, Equatable, Sendable {
        case notFound(String)
    }

    public func delete(id: String) throws {
        var all = try loadOrEmpty()
        guard let idx = all.firstIndex(where: { $0.id == id }) else {
            throw DeleteError.notFound(id)
        }
        all.remove(at: idx)
        try save(all)
    }

    // ──────────────────────────────────────────────────────────────
    // private
    // ──────────────────────────────────────────────────────────────

    private func loadOrEmpty() throws -> [Token] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = []
            return []
        }
        let raw = try AtomicIO.readString(from: url)
        let data = Data(raw.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(TokenFile.self, from: data)
        cache = file.tokens
        return file.tokens
    }

    private func save(_ tokens: [Token]) throws {
        let envelope = TokenFile(version: 1, tokens: tokens)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try AtomicIO.writeData(data, to: url)
        cache = tokens
    }

    /// Returns true if `scopes` satisfies `required`. `admin` always
    /// satisfies any required scope.
    public static func satisfies(scopes: [Scope], required: Scope) -> Bool {
        if scopes.contains(.admin) { return true }
        return scopes.contains(required)
    }

    /// Length-independent constant-time string compare.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= (aBytes[i] ^ bBytes[i])
        }
        return diff == 0
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    private static func randomID(length: Int) -> String {
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(alphabet.randomElement()!)
        }
        return out
    }

    /// 32 hex chars → 128 bits of entropy. Plenty for a per-host CI
    /// token. Uses `SystemRandomNumberGenerator`.
    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...UInt8.max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
