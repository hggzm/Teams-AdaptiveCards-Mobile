import Foundation

/// Phase 30 — Redis ACL (multi-user authentication + per-command +
/// per-key-pattern authorization).
///
/// Process-wide registry of `ACLUser`s. Looks them up by name during
/// `AUTH user password`; the dispatcher then attaches the resulting
/// user to its `ConnectionState` and consults `user.allows(command:)`
/// before running each subsequent command.
///
/// Storage is in-memory only. The `default` user is auto-created with
/// the legacy-friendly profile `on nopass ~* +@all` so existing
/// single-password code paths keep working unchanged (the dispatcher
/// promotes the constructor-supplied `requiredPassword` to a real
/// password on the default user when provided).
public final class ACLStore: @unchecked Sendable {

    /// Information about a single ACL user. Mirrors the rule vocabulary
    /// `redis.conf` accepts in `user ...` directives.
    public final class ACLUser: @unchecked Sendable {
        public let name: String
        /// `on` (true) means the user can authenticate; `off` (false)
        /// rejects all AUTH attempts even with a matching password.
        public var enabled: Bool = false
        /// `nopass`: any password authenticates as this user. Mutually
        /// exclusive with stored hashes — setting one clears the other.
        public var nopass: Bool = false
        /// SHA-256 of every accepted password (Redis-style — stored as
        /// lowercase hex). Empty when `nopass == true`.
        public var passwordHashes: Set<String> = []
        /// `+@all` shortcut. When true, the user can run every command.
        public var allowAllCommands: Bool = false
        /// Explicit `+command` allowlist. Only consulted when
        /// `allowAllCommands == false`.
        public var allowedCommands: Set<String> = []
        /// Explicit `-command` denylist. Wins over allowAllCommands and
        /// allowedCommands when matched.
        public var deniedCommands: Set<String> = []
        /// Glob patterns from `~pattern` rules. `["*"]` means any key.
        /// Empty means the user can't touch any key.
        public var keyPatterns: [String] = []

        public init(name: String) {
            self.name = name
        }

        /// Returns true if `name` is on the allowlist (and not on the
        /// denylist). Command-name comparison is case-insensitive.
        public func allows(command: String) -> Bool {
            let cmd = command.uppercased()
            if deniedCommands.contains(cmd) { return false }
            if allowAllCommands { return true }
            return allowedCommands.contains(cmd)
        }

        /// Returns true if `key` matches one of the user's `~pattern`
        /// rules. Used by callers that want per-key authorisation; the
        /// default dispatcher currently only checks command-level
        /// rules but the API is here for future phases.
        public func matchesKey(_ key: String) -> Bool {
            for pat in keyPatterns {
                if pat == "*" { return true }
                if let r = try? KeyStore.compileGlob(pat) {
                    let ns = key as NSString
                    if r.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)) != nil {
                        return true
                    }
                }
            }
            return false
        }

        /// Verifies `password` against the user's stored hashes (or
        /// returns true unconditionally if `nopass`).
        public func acceptsPassword(_ password: String) -> Bool {
            if nopass { return true }
            let hash = ACLStore.sha256Hex(password)
            return passwordHashes.contains(hash)
        }
    }

    private let lock = NSLock()
    /// Users indexed by name. `default` always exists.
    private var users: [String: ACLUser] = [:]

    public init() {
        let def = ACLUser(name: "default")
        // Matches Redis: the bootstrapped `default` user is `on nopass
        // ~* +@all` so the legacy single-password / no-auth path keeps
        // working unchanged.
        def.enabled = true
        def.nopass = true
        def.allowAllCommands = true
        def.keyPatterns = ["*"]
        users["default"] = def
    }

    /// Looks up a user by name. Returns `nil` for unknown users.
    public func user(named name: String) -> ACLUser? {
        lock.lock(); defer { lock.unlock() }
        return users[name]
    }

    /// Authenticates `name` / `password`. Returns the matching user
    /// when the credentials are valid and the user is enabled; `nil`
    /// otherwise.
    public func authenticate(name: String, password: String) -> ACLUser? {
        lock.lock(); defer { lock.unlock() }
        guard let u = users[name], u.enabled, u.acceptsPassword(password) else {
            return nil
        }
        return u
    }

    /// Returns the names of every registered user. Sort order is the
    /// insertion order of `setUser` — Redis sorts alphabetically, which
    /// we mirror in the caller via `.sorted()`.
    public func list() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(users.keys)
    }

    /// Removes the named users. Refuses to delete `default` (Redis
    /// behaviour). Returns the number of users actually removed.
    @discardableResult
    public func deleteUsers(_ names: [String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for name in names {
            if name == "default" { continue }
            if users.removeValue(forKey: name) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Applies a list of ACL rule tokens to a user, creating it if
    /// needed. Returns the affected user. Throws on syntax errors.
    @discardableResult
    public func setUser(name: String, rules: [String]) throws -> ACLUser {
        lock.lock(); defer { lock.unlock() }
        let user = users[name] ?? ACLUser(name: name)
        for raw in rules {
            try Self.apply(rule: raw, to: user)
        }
        users[name] = user
        return user
    }

    /// Convenience: drops every password and turns the user off.
    public func reset(name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let u = users[name] else { return }
        u.enabled = false
        u.nopass = false
        u.passwordHashes.removeAll()
        u.allowAllCommands = false
        u.allowedCommands.removeAll()
        u.deniedCommands.removeAll()
        u.keyPatterns.removeAll()
    }

    /// Renders a user's profile as the same one-line string Redis
    /// uses for `ACL LIST` / `ACL GETUSER`. Format:
    ///   user <name> on/off [nopass | #<hash>...] [~pattern...] [+cmd|-cmd...]
    public func format(_ user: ACLUser) -> String {
        var parts: [String] = ["user", user.name]
        parts.append(user.enabled ? "on" : "off")
        if user.nopass {
            parts.append("nopass")
        } else {
            for h in user.passwordHashes.sorted() {
                parts.append("#\(h)")
            }
        }
        for pat in user.keyPatterns {
            parts.append("~\(pat)")
        }
        if user.allowAllCommands {
            parts.append("+@all")
        }
        for cmd in user.allowedCommands.sorted() {
            parts.append("+\(cmd.lowercased())")
        }
        for cmd in user.deniedCommands.sorted() {
            parts.append("-\(cmd.lowercased())")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - rule parsing

    /// Apply a single rule token (e.g. `on`, `nopass`, `>pw`, `~user:*`,
    /// `+get`, `-set`, `+@all`, `nocommands`, `resetpass`, `resetkeys`,
    /// `reset`).
    static func apply(rule: String, to user: ACLUser) throws {
        switch rule {
        case "on":          user.enabled = true
        case "off":         user.enabled = false
        case "nopass":      user.nopass = true; user.passwordHashes.removeAll()
        case "resetpass":   user.nopass = false; user.passwordHashes.removeAll()
        case "resetkeys":   user.keyPatterns.removeAll()
        case "allkeys":     user.keyPatterns = ["*"]
        case "allcommands", "+@all":
            user.allowAllCommands = true
            user.allowedCommands.removeAll()
            user.deniedCommands.removeAll()
        case "nocommands", "-@all":
            user.allowAllCommands = false
            user.allowedCommands.removeAll()
            user.deniedCommands.removeAll()
        case "reset":
            user.enabled = true
            user.nopass = false
            user.passwordHashes.removeAll()
            user.allowAllCommands = false
            user.allowedCommands.removeAll()
            user.deniedCommands.removeAll()
            user.keyPatterns.removeAll()
        default:
            guard !rule.isEmpty else {
                throw KeyStoreError.appError("ERR Syntax error")
            }
            let first = rule.first!
            let rest = String(rule.dropFirst())
            switch first {
            case ">":
                user.nopass = false
                user.passwordHashes.insert(sha256Hex(rest))
            case "<":
                user.passwordHashes.remove(sha256Hex(rest))
            case "#":
                user.nopass = false
                user.passwordHashes.insert(rest.lowercased())
            case "!":
                user.passwordHashes.remove(rest.lowercased())
            case "~":
                user.keyPatterns.append(rest)
            case "+":
                // `+@category` shortcut maps to allowAllCommands.
                if rest == "@all" {
                    user.allowAllCommands = true
                    user.allowedCommands.removeAll()
                    user.deniedCommands.removeAll()
                } else if rest.hasPrefix("@") {
                    // Categories other than @all are accepted but
                    // mapped to allowAllCommands (single-tier ACL in
                    // swiftka v0.12.0).
                    user.allowAllCommands = true
                } else {
                    user.allowedCommands.insert(rest.uppercased())
                }
            case "-":
                if rest == "@all" {
                    user.allowAllCommands = false
                    user.allowedCommands.removeAll()
                } else if rest.hasPrefix("@") {
                    user.allowAllCommands = false
                } else {
                    user.deniedCommands.insert(rest.uppercased())
                }
            default:
                throw KeyStoreError.appError("ERR Unrecognised parameter: \(rule)")
            }
        }
    }

    /// SHA-256 hex digest of a string, formatted lowercase — the same
    /// format Redis uses for ACL `#<hash>` rules.
    public static func sha256Hex(_ s: String) -> String {
        let bytes = [UInt8](s.utf8)
        let digest = sha256(bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - pure-Swift SHA-256
    //
    // RFC 6234 / FIPS 180-4. Same compact implementation pattern used
    // elsewhere; avoids pulling CommonCrypto on Apple-only or
    // CryptoKit which is missing on swift-corelibs-foundation Linux
    // before 5.10. Pure swift keeps Windows + Linux + Apple identical.

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var msg = data
        let bitLen = UInt64(data.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0...7).reversed() {
            msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff))
        }
        let blocks = msg.count / 64
        for b in 0..<blocks {
            let base = b * 64
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = base + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16) |
                       (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], bb = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & bb) ^ (a & c) ^ (bb & c)
                let t2 = S0 &+ mj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = bb
                bb = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ bb
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
