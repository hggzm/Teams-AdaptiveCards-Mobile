// hggz/giteax — Phase 19: Personal Access Tokens (PATs).
//
// PATs are a per-user revocable substitute for the user's password
// when authenticating to the giteax HTTP API and to git-over-https /
// LFS / package endpoints. Functionally they behave like GitHub's
// classic PATs: bearer tokens that authenticate AS a specific user,
// inheriting that user's permissions through the existing
// `UserStore` + `AccessController` machinery.
//
// **Storage model.** One global JSON envelope at
// `<root>/.giteax/tokens.json`:
//
//     { version: 1,
//       nextID: <Int>,
//       tokens: [
//         { id, owner, name,
//           prefix,           -- first 12 chars of the plaintext for UI / list display
//           hash,             -- hex(SHA-256(plaintext)) -- plaintext NEVER stored
//           createdAt,
//           lastUsedAt? }, ...
//       ] }
//
// Plaintext is shown to the caller exactly once, as the response body
// of `POST /api/users/:name/tokens`. After that the only way to
// authenticate with a token is to present it; the server can only
// verify by hashing and comparing.
//
// **Wire format.** The plaintext token is
//
//     giteax_pat_<43-char base64url of 32 random bytes>
//
// — 32 bytes of `SystemRandomNumberGenerator` entropy, encoded
// without padding. The literal `giteax_pat_` prefix lets callers
// distinguish PATs from passwords at a glance and lets the
// auth gate short-circuit obvious non-PAT inputs.
//
// **Security.** SHA-256 of the plaintext is what's stored. That's
// enough for high-entropy random tokens (32 bytes ≈ 256 bits of
// entropy; precomputed-rainbow attacks are infeasible). bcrypt would
// be overkill and slow; the protection model here is "the server
// disk is trusted; tokens-on-disk are useless without the prefix
// component which is also stored to assist the user but is NOT
// secret".
//
// Scopes are intentionally NOT modeled in this revision. A PAT
// authenticates AS the user; the user's existing access level (read /
// write / admin via `AccessController`) governs what the request can
// do. A future phase can add fine-grained scopes if needed; the
// envelope `version: 1` flag leaves room.

import Foundation
import Vapor
import Crypto

actor TokenStore {

    /// Public-facing record. The plaintext is intentionally absent —
    /// the only place it ever appears is the `plaintext` field on the
    /// `Created` envelope returned from `create(...)`.
    struct Token: Sendable, Codable {
        let id: Int
        let owner: String        // matches UserStore name
        var name: String         // user-supplied label (e.g. "laptop", "ci")
        let prefix: String       // first 12 chars of the plaintext, for display
        let hash: String         // hex(SHA-256(plaintext))
        let createdAt: Date
        var lastUsedAt: Date?
    }

    /// Returned from `create(...)` exactly once. The caller MUST
    /// surface `plaintext` to the human and discard it; the server
    /// cannot recover it.
    struct Created: Sendable {
        let token: Token
        let plaintext: String
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextID: Int
        var tokens: [Token]
    }

    enum StoreError: Error, AbortError {
        case invalidInput(String)
        case notFound(id: Int)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidInput: .badRequest
            case .notFound:     .notFound
            case .ioFailed:     .internalServerError
            case .badEnvelope:  .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .invalidInput(let s): "invalid token input: \(s)"
            case .notFound(let id):    "token #\(id) not found"
            case .ioFailed(let s):     "token store I/O: \(s)"
            case .badEnvelope(let s):  "token envelope: \(s)"
            }
        }
    }

    static let plaintextPrefix = "giteax_pat_"

    private let root: URL
    private var cache: Envelope?

    init(root: URL) throws {
        self.root = root
        // Lazy-load on first call; the routes layer will warm it.
    }

    // MARK: - Persistence

    private func envelopeURL() -> URL {
        root.appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("tokens.json", isDirectory: false)
    }

    @discardableResult
    private func loadOrInit() throws -> Envelope {
        if let cache { return cache }
        let url = envelopeURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = Envelope(version: 1, nextID: 1, tokens: [])
            cache = fresh
            return fresh
        }
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let env = try dec.decode(Envelope.self, from: data)
            cache = env
            return env
        } catch {
            throw StoreError.badEnvelope("\(error)")
        }
    }

    private func persist(_ env: Envelope) throws {
        let url = envelopeURL()
        let parent = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw StoreError.ioFailed("mkdir: \(error)") }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do { data = try enc.encode(env) } catch { throw StoreError.ioFailed("encode: \(error)") }
        let tmp = parent.appendingPathComponent("tokens.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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
        cache = env
    }

    // MARK: - Public API

    /// List all tokens for `owner`. Plaintext is never returned;
    /// callers see `prefix` plus metadata.
    func list(owner: String) throws -> [Token] {
        let env = try loadOrInit()
        return env.tokens.filter { $0.owner == owner }.sorted { $0.id < $1.id }
    }

    /// Create a new token. Returns the record AND the plaintext —
    /// this is the ONLY moment in the token's lifetime that the
    /// plaintext is available.
    @discardableResult
    func create(owner: String, name: String) throws -> Created {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidInput("token name is empty") }
        guard trimmed.count <= 100 else { throw StoreError.invalidInput("token name too long (>100)") }
        let plaintext = Self.generatePlaintext()
        let hash = Self.hash(plaintext: plaintext)
        let displayPrefix = String(plaintext.prefix(12))
        var env = try loadOrInit()
        let token = Token(
            id: env.nextID,
            owner: owner,
            name: trimmed,
            prefix: displayPrefix,
            hash: hash,
            createdAt: Date(),
            lastUsedAt: nil
        )
        env.nextID += 1
        env.tokens.append(token)
        try persist(env)
        return Created(token: token, plaintext: plaintext)
    }

    /// Delete a token by id. Owner check is done at the route layer.
    func delete(id: Int) throws {
        var env = try loadOrInit()
        guard let idx = env.tokens.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound(id: id)
        }
        env.tokens.remove(at: idx)
        try persist(env)
    }

    /// Auth-time lookup: hash the candidate plaintext and look it up.
    /// Updates `lastUsedAt` on a hit. Constant-time comparison is not
    /// strictly required because the comparand is derived from the
    /// presented input only via hashing (no length-leak), but we use
    /// a constant-time comparison anyway.
    func verify(plaintext: String) throws -> Token? {
        guard plaintext.hasPrefix(Self.plaintextPrefix) else { return nil }
        let candidateHash = Self.hash(plaintext: plaintext)
        var env = try loadOrInit()
        guard let idx = env.tokens.firstIndex(where: {
            Self.constantTimeEqual($0.hash, candidateHash)
        }) else { return nil }
        env.tokens[idx].lastUsedAt = Date()
        // Best-effort persist of lastUsedAt; don't fail auth if disk
        // I/O fails.
        try? persist(env)
        return env.tokens[idx]
    }

    // MARK: - Crypto helpers

    /// Generate a 32-byte random suffix and prepend the
    /// `giteax_pat_` literal. Total token length = 11 + 43 = 54
    /// chars; matches the GitHub-style "fixed prefix + base64url"
    /// scheme.
    static func generatePlaintext() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SystemRandomNumberGenerator on every supported platform
        // (macOS / Linux / Windows) reads from a real CSPRNG.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        let b64 = Data(bytes).base64URLEncodedNoPaddingString()
        return plaintextPrefix + b64
    }

    static func hash(plaintext: String) -> String {
        let bytes = Array(plaintext.utf8)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Length-equal SHA-256-hex strings can be compared in constant
    /// time without allocations.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

// MARK: - Data base64url

private extension Data {
    /// Base64url encoding without padding (`-` / `_` alphabet, no
    /// trailing `=`). Matches the convention used by JWT and GitHub
    /// PATs.
    func base64URLEncodedNoPaddingString() -> String {
        var s = self.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }
}

// MARK: - Routes

/// Phase 19 PAT management endpoints. Pattern mirrors
/// `registerSSHKeyRoutes`: self-or-admin authorization, with the
/// admin path accepting a Bearer header carrying `GITEAX_ADMIN_TOKEN`
/// and the self path accepting either Basic auth (password) OR a PAT
/// (Basic password OR Bearer header).
///
///   GET    /api/users/:name/tokens             (self or admin)
///   POST   /api/users/:name/tokens             (self or admin)
///          body: { "name": "<label>" }
///          response: { ..., "token": "<plaintext>" } -- shown ONCE
///   DELETE /api/users/:name/tokens/:id         (self or admin)
func registerTokenRoutes(
    _ app: Application,
    tokenStore: TokenStore,
    userStore: UserStore,
    adminToken: String?
) {
    @Sendable
    func authorize(_ req: Request, owner: String) async throws {
        // 1. Admin Bearer token.
        if let bearer = req.headers.bearerAuthorization,
           let adminToken, bearer.token == adminToken {
            return
        }
        // 2. Bearer that's actually a PAT.
        if let bearer = req.headers.bearerAuthorization,
           bearer.token.hasPrefix(TokenStore.plaintextPrefix),
           let tok = try await tokenStore.verify(plaintext: bearer.token) {
            if tok.owner == owner { return }
            // PATs authenticate AS a user; if that user is admin,
            // grant.
            if let u = await userStore.get(tok.owner), u.isAdmin { return }
            throw Abort(.forbidden, reason: "you may only manage your own tokens")
        }
        // 3. Basic auth: password may be either the user's password OR a PAT.
        guard let basic = req.headers.basicAuthorization else {
            var h = HTTPHeaders()
            h.add(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: h, reason: "authentication required")
        }
        let resolved: UserStore.User?
        if basic.password.hasPrefix(TokenStore.plaintextPrefix),
           let tok = try await tokenStore.verify(plaintext: basic.password) {
            resolved = await userStore.get(tok.owner)
        } else {
            resolved = await userStore.verify(name: basic.username, password: basic.password)
        }
        guard let user = resolved else {
            var h = HTTPHeaders()
            h.add(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: h, reason: "invalid credentials")
        }
        if user.name == owner { return }
        if user.isAdmin { return }
        throw Abort(.forbidden, reason: "you may only manage your own tokens")
    }

    app.get("api", "users", ":name", "tokens") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        try await authorize(req, owner: name)
        let toks = try await tokenStore.list(owner: name)
        let dto = TokenListDTO(owner: name, count: toks.count, tokens: toks.map(TokenDTO.from))
        let r = Response(status: .ok)
        try r.content.encode(dto, as: .json)
        return r
    }

    app.post("api", "users", ":name", "tokens") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        try await authorize(req, owner: name)
        // Owner must exist as a user; this matches the SSH-keys route shape.
        guard await userStore.get(name) != nil else {
            throw Abort(.notFound, reason: "user '\(name)' not found")
        }
        let body = try req.content.decode(CreateTokenDTO.self)
        do {
            let created = try await tokenStore.create(owner: name, name: body.name)
            let r = Response(status: .created)
            try r.content.encode(TokenCreatedDTO.from(created), as: .json)
            return r
        } catch let e as TokenStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "users", ":name", "tokens", ":id") { req async throws -> Response in
        guard let name = req.parameters.get("name"),
              let id = req.parameters.get("id", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :name or :id") }
        try await authorize(req, owner: name)
        // Confirm the token belongs to :name before deleting (mirrors SSH).
        let owned = try await tokenStore.list(owner: name)
        guard owned.contains(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "token #\(id) not found for user '\(name)'")
        }
        do { try await tokenStore.delete(id: id) }
        catch let e as TokenStore.StoreError { throw Abort(e.status, reason: e.reason) }
        return Response(status: .noContent)
    }
}

private struct CreateTokenDTO: Content {
    let name: String
}

private struct TokenDTO: Content {
    let id: Int
    let owner: String
    let name: String
    let prefix: String
    let createdAt: Date
    let lastUsedAt: Date?

    static func from(_ t: TokenStore.Token) -> TokenDTO {
        TokenDTO(id: t.id, owner: t.owner, name: t.name, prefix: t.prefix,
                 createdAt: t.createdAt, lastUsedAt: t.lastUsedAt)
    }
}

private struct TokenListDTO: Content {
    let owner: String
    let count: Int
    let tokens: [TokenDTO]
}

private struct TokenCreatedDTO: Content {
    let id: Int
    let owner: String
    let name: String
    let prefix: String
    let createdAt: Date
    /// Plaintext token. Returned exactly ONCE on creation. Discard
    /// after copying; the server cannot recover it.
    let token: String

    static func from(_ c: TokenStore.Created) -> TokenCreatedDTO {
        TokenCreatedDTO(id: c.token.id, owner: c.token.owner, name: c.token.name,
                        prefix: c.token.prefix, createdAt: c.token.createdAt,
                        token: c.plaintext)
    }
}