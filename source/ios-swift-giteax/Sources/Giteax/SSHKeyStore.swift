// hggz/giteax -- Phase 15a: SSH public-key store + management API.
//
// Storage model:
//
//   <root>/.giteax/ssh-keys.json
//     { version: 1,
//       nextID: <Int>,
//       keys: [
//         { id, owner, title, fingerprint, openssh, createdAt }, ...
//       ] }
//
// One global file (not per-user) so the SSH server can look up by
// fingerprint in O(N) without walking a directory. N ~ user-count *
// keys-per-user; for any realistic personal deployment this fits in
// memory comfortably.
//
// API:
//
//   GET    /api/users/:name/ssh-keys                       (authed: self OR admin)
//   POST   /api/users/:name/ssh-keys                       (authed: self OR admin)
//          body: { title, key }    -- key is OpenSSH "ssh-ed25519 AAAA..." line
//   DELETE /api/users/:name/ssh-keys/:id                   (authed: self OR admin)
//
// The actual SSH server authenticator (Phase 15b) consults this store
// at connection time to map an incoming public key -> username.

import Vapor
import Foundation
import Crypto

actor SSHKeyStore {

    struct Key: Sendable, Codable {
        let id: Int
        let owner: String        // matches UserStore name
        var title: String
        let fingerprint: String  // sha256:<base64> (OpenSSH-style)
        let openssh: String      // canonical "<type> <base64> [comment]"
        let createdAt: Date
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var nextID: Int
        var keys: [Key]
    }

    enum StoreError: Error, AbortError {
        case invalidInput(String)
        case duplicate(fingerprint: String)
        case notFound(id: Int)
        case ioFailed(String)
        case badEnvelope(String)

        var status: HTTPResponseStatus {
            switch self {
            case .invalidInput: .badRequest
            case .duplicate:    .conflict
            case .notFound:     .notFound
            case .ioFailed:     .internalServerError
            case .badEnvelope:  .internalServerError
            }
        }
        var reason: String {
            switch self {
            case .invalidInput(let s):    "invalid SSH key input: \(s)"
            case .duplicate(let f):       "SSH key with fingerprint \(f) already registered"
            case .notFound(let id):       "SSH key #\(id) not found"
            case .ioFailed(let s):        "SSH key store I/O: \(s)"
            case .badEnvelope(let s):     "SSH key envelope: \(s)"
            }
        }
    }

    private let root: URL
    private var cache: Envelope?

    init(root: URL) throws {
        self.root = root
        // We can't call actor-isolated methods from init synchronously.
        // Lazy load on first call to list()/add()/lookup() instead -- the
        // SSH listener (Phase 15b) will warm it during startup.
    }

    private func envelopeURL() -> URL {
        root
            .appendingPathComponent(".giteax", isDirectory: true)
            .appendingPathComponent("ssh-keys.json", isDirectory: false)
    }

    @discardableResult
    private func loadOrInit() throws -> Envelope {
        if let cache { return cache }
        let url = envelopeURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = Envelope(version: 1, nextID: 1, keys: [])
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
        let tmp = parent.appendingPathComponent("ssh-keys.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

    func list(owner: String? = nil) throws -> [Key] {
        var env = try loadOrInit()
        if let owner {
            env.keys = env.keys.filter { $0.owner == owner }
        }
        return env.keys.sorted { $0.id < $1.id }
    }

    func get(id: Int) throws -> Key {
        let env = try loadOrInit()
        guard let k = env.keys.first(where: { $0.id == id }) else {
            throw StoreError.notFound(id: id)
        }
        return k
    }

    @discardableResult
    func add(owner: String, title: String, openssh: String) throws -> Key {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw StoreError.invalidInput("title is empty") }
        guard trimmedTitle.count <= 200 else { throw StoreError.invalidInput("title too long (>200)") }
        let (canonical, fp) = try Self.parseAndFingerprint(openssh)
        var env = try loadOrInit()
        if env.keys.contains(where: { $0.fingerprint == fp }) {
            throw StoreError.duplicate(fingerprint: fp)
        }
        let k = Key(
            id: env.nextID, owner: owner, title: trimmedTitle,
            fingerprint: fp, openssh: canonical,
            createdAt: Date()
        )
        env.nextID += 1
        env.keys.append(k)
        try persist(env)
        return k
    }

    func delete(id: Int) throws {
        var env = try loadOrInit()
        guard let idx = env.keys.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound(id: id)
        }
        env.keys.remove(at: idx)
        try persist(env)
    }

    /// Phase 15b: look up a key by its raw base64-encoded blob (the
    /// `AAAA…` middle field of the OpenSSH line). Returns the (owner,
    /// fingerprint) pair when matched.
    func lookup(rawBase64: String) throws -> (owner: String, fingerprint: String)? {
        let env = try loadOrInit()
        for k in env.keys {
            // Extract base64 from the canonical "<type> <base64> [comment]"
            // we stored.
            let parts = k.openssh.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { continue }
            if String(parts[1]) == rawBase64 {
                return (k.owner, k.fingerprint)
            }
        }
        return nil
    }

    // MARK: - Parser

    /// Parse an OpenSSH authorized_keys line. Accepted types: `ssh-ed25519`,
    /// `ssh-rsa`, `ecdsa-sha2-nistp256/384/521`, `ssh-dss` (legacy). Returns
    /// the canonicalised "<type> <base64> [comment]" form and the SHA-256
    /// fingerprint in OpenSSH "SHA256:<base64-without-padding>" form.
    private static let allowedTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ssh-dss",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    static func parseAndFingerprint(_ input: String) throws -> (canonical: String, fingerprint: String) {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw StoreError.invalidInput("empty key") }
        let parts = cleaned.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { throw StoreError.invalidInput("expected '<type> <base64> [comment]'") }
        let type = String(parts[0])
        let b64 = String(parts[1])
        guard allowedTypes.contains(type) else {
            throw StoreError.invalidInput("unsupported key type '\(type)'")
        }
        guard let blob = Data(base64Encoded: b64) else {
            throw StoreError.invalidInput("not valid base64 in the key body")
        }
        guard blob.count >= 4 else { throw StoreError.invalidInput("key blob too short") }
        // SHA-256 fingerprint, OpenSSH-style: "SHA256:<base64-no-padding>".
        let digest = SHA256.hash(data: blob)
        let fpData = Data(digest)
        let fpB64 = fpData.base64EncodedString().trimmingCharacters(in: ["="])
        let fingerprint = "SHA256:\(fpB64)"
        // Canonical form: "<type> <base64> [comment]".
        let comment = parts.count == 3 ? " \(parts[2].trimmingCharacters(in: .whitespaces))" : ""
        let canonical = "\(type) \(b64)\(comment)"
        return (canonical, fingerprint)
    }
}

// MARK: - Routes

func registerSSHKeyRoutes(
    _ app: Application,
    keyStore: SSHKeyStore,
    userStore: UserStore,
    adminToken: String?
) {
    /// Returns the authenticated owner name when:
    ///   - admin token (Bearer) is presented, OR
    ///   - Basic auth resolves to the same user as :name OR a global admin
    @Sendable
    func authorize(_ req: Request, owner: String) async throws {
        // Admin path: Bearer <admin token>.
        if let bearer = req.headers.bearerAuthorization,
           let adminToken, bearer.token == adminToken {
            return
        }
        // Basic auth path: must match :name or be a global admin.
        guard let basic = req.headers.basicAuthorization else {
            var h = HTTPHeaders()
            h.add(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: h, reason: "authentication required")
        }
        guard let user = await userStore.verify(name: basic.username, password: basic.password) else {
            var h = HTTPHeaders()
            h.add(name: .wwwAuthenticate, value: #"Basic realm="giteax""#)
            throw Abort(.unauthorized, headers: h, reason: "invalid credentials")
        }
        if user.name == owner { return }
        if user.isAdmin { return }
        throw Abort(.forbidden, reason: "you may only manage your own SSH keys")
    }

    app.get("api", "users", ":name", "ssh-keys") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        try await authorize(req, owner: name)
        let keys = try await keyStore.list(owner: name)
        let dto = SSHKeyListDTO(owner: name, count: keys.count,
                                keys: keys.map(SSHKeyDTO.from))
        let r = Response(status: .ok)
        try r.content.encode(dto, as: .json)
        return r
    }

    app.post("api", "users", ":name", "ssh-keys") { req async throws -> Response in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "missing :name")
        }
        try await authorize(req, owner: name)
        let body = try req.content.decode(AddSSHKeyDTO.self)
        do {
            let k = try await keyStore.add(owner: name, title: body.title, openssh: body.key)
            let r = Response(status: .created)
            try r.content.encode(SSHKeyDTO.from(k), as: .json)
            return r
        } catch let e as SSHKeyStore.StoreError {
            throw Abort(e.status, reason: e.reason)
        }
    }

    app.delete("api", "users", ":name", "ssh-keys", ":id") { req async throws -> Response in
        guard let name = req.parameters.get("name"),
              let id = req.parameters.get("id", as: Int.self)
        else { throw Abort(.badRequest, reason: "missing :name or :id") }
        try await authorize(req, owner: name)
        // Make sure the key belongs to :name before deleting.
        let key: SSHKeyStore.Key
        do { key = try await keyStore.get(id: id) }
        catch let e as SSHKeyStore.StoreError { throw Abort(e.status, reason: e.reason) }
        guard key.owner == name else {
            throw Abort(.notFound, reason: "SSH key #\(id) not found for user '\(name)'")
        }
        do { try await keyStore.delete(id: id) }
        catch let e as SSHKeyStore.StoreError { throw Abort(e.status, reason: e.reason) }
        return Response(status: .noContent)
    }
}

private struct AddSSHKeyDTO: Content {
    let title: String
    let key: String
}

private struct SSHKeyDTO: Content {
    let id: Int
    let owner: String
    let title: String
    let fingerprint: String
    let openssh: String
    let createdAt: Date

    static func from(_ k: SSHKeyStore.Key) -> SSHKeyDTO {
        SSHKeyDTO(id: k.id, owner: k.owner, title: k.title,
                  fingerprint: k.fingerprint, openssh: k.openssh,
                  createdAt: k.createdAt)
    }
}

private struct SSHKeyListDTO: Content {
    let owner: String
    let count: Int
    let keys: [SSHKeyDTO]
}
