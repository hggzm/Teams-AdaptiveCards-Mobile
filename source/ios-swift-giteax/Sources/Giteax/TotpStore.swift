import Foundation
import Crypto

/// Filesystem-backed TOTP (RFC 6238, SHA-1, 30 s, 6 digits) store.
///
/// On-disk shape (`<root>/.giteax/totp.json`):
///
///     {
///       "version": 1,
///       "entries": [
///         {
///           "name": "alice",
///           "secret": "JBSWY3DPEHPK3PXP...",  // base32, no padding
///           "active": true,
///           "pending": false,
///           "recoveryHashes": ["<sha256-hex>", ...],
///           "createdAt": "...",
///           "activatedAt": "..."
///         }
///       ]
///     }
///
/// Lifecycle:
///   - `setup(user:)` -> creates/replaces an entry in `pending` state,
///     returns the raw secret + plaintext recovery codes (ONE TIME).
///   - `activate(user:code:)` -> verifies a 6-digit TOTP against the
///     pending secret, promotes the entry to `active`.
///   - `verify(user:code:)` -> verifies a 6-digit TOTP against an
///     active entry. Accepts +/- 1 step skew.
///   - `useRecoveryCode(user:code:)` -> consumes one matching recovery
///     code (compared by SHA-256 hash). Single-use.
///   - `disable(user:)` -> wipes the entry entirely.
///
/// Persistence uses the same remove-then-move atomic write pattern as
/// `UserStore` (Windows-portable; `replaceItemAt` is unimplemented on
/// swift-corelibs-foundation/Windows).
actor TotpStore {
    struct Entry: Sendable, Codable {
        let name: String
        var secret: String              // base32, no padding
        var active: Bool
        var pending: Bool
        var recoveryHashes: [String]    // sha256(hex) of plaintext recovery codes
        let createdAt: Date
        var activatedAt: Date?
    }

    private struct Envelope: Sendable, Codable {
        var version: Int
        var entries: [Entry]
    }

    struct SetupResult: Sendable {
        let secret: String              // base32
        let otpauthURI: String          // otpauth://totp/...
        let recoveryCodes: [String]     // plaintext, returned ONCE
    }

    enum StoreError: Error, CustomStringConvertible {
        case ioFailed(String)
        case badEnvelope(String)
        var description: String {
            switch self {
            case .ioFailed(let s):    return "totp-store I/O: \(s)"
            case .badEnvelope(let s): return "totp-store envelope: \(s)"
            }
        }
    }

    let storePath: URL
    private var envelope: Envelope
    /// Issuer label embedded in the otpauth URI (visible in TOTP apps).
    private let issuer: String

    init(root: URL, issuer: String = "giteax") throws {
        let giteaxDir = root.appendingPathComponent(".giteax", isDirectory: true)
        try FileManager.default.createDirectory(at: giteaxDir, withIntermediateDirectories: true)
        self.storePath = giteaxDir.appendingPathComponent("totp.json")
        self.issuer = issuer
        if FileManager.default.fileExists(atPath: storePath.path) {
            do {
                let data = try Data(contentsOf: storePath)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                self.envelope = try dec.decode(Envelope.self, from: data)
            } catch {
                throw StoreError.badEnvelope(String(describing: error))
            }
        } else {
            self.envelope = Envelope(version: 1, entries: [])
            try Self.persist(envelope, to: storePath)
        }
    }

    // MARK: - Read

    /// `(enabled, pending)` view. `enabled == true` means an active TOTP
    /// secret exists; `pending == true` means setup was called but
    /// activate hasn't been completed yet.
    func status(user: String) -> (enabled: Bool, pending: Bool) {
        guard let e = entry(user) else { return (false, false) }
        return (e.active, e.pending)
    }

    /// Number of unused recovery codes remaining for `user`. Returns 0
    /// if no TOTP entry exists.
    func recoveryCodeCount(user: String) -> Int {
        entry(user)?.recoveryHashes.count ?? 0
    }

    // MARK: - Mutate

    /// Generate a fresh secret + 10 recovery codes; store in pending
    /// state (replaces any existing entry, active or not, for `user`).
    /// Returns the plaintext secret and recovery codes -- callers MUST
    /// surface these to the user immediately; they are never returned
    /// again.
    func setup(user: String) throws -> SetupResult {
        let rawSecret = Self.randomBytes(20)
        let base32 = Self.base32Encode(rawSecret)
        let plainCodes = (0..<10).map { _ in Self.randomRecoveryCode() }
        let hashed = plainCodes.map { Self.sha256Hex(Self.normaliseRecoveryCode($0)) }
        let now = Date()
        let newEntry = Entry(
            name: user,
            secret: base32,
            active: false,
            pending: true,
            recoveryHashes: hashed,
            createdAt: now,
            activatedAt: nil
        )
        envelope.entries.removeAll(where: { $0.name == user })
        envelope.entries.append(newEntry)
        try Self.persist(envelope, to: storePath)
        let uri = Self.otpauthURI(issuer: issuer, account: user, base32Secret: base32)
        return SetupResult(secret: base32, otpauthURI: uri, recoveryCodes: plainCodes)
    }

    /// Verify a code against the pending entry; on success promote to
    /// active. Returns true on success; false if no pending entry or
    /// the code is wrong. The pending entry is left in place on
    /// failure so the user can retry without re-running setup.
    func activate(user: String, code: String) throws -> Bool {
        guard let idx = envelope.entries.firstIndex(where: { $0.name == user }) else {
            return false
        }
        let e = envelope.entries[idx]
        guard e.pending, !e.active else { return false }
        guard Self.verifyTotp(base32Secret: e.secret, code: code, at: Date()) else {
            return false
        }
        envelope.entries[idx].pending = false
        envelope.entries[idx].active = true
        envelope.entries[idx].activatedAt = Date()
        try Self.persist(envelope, to: storePath)
        return true
    }

    /// Verify a TOTP code against the active entry for `user`. Returns
    /// true if the entry is active and the code matches the current
    /// 30-s step or +/- 1 step skew.
    func verify(user: String, code: String) -> Bool {
        guard let e = entry(user), e.active else { return false }
        return Self.verifyTotp(base32Secret: e.secret, code: code, at: Date())
    }

    /// Consume one recovery code. Returns true if matched (and removes
    /// it from the on-disk list). False if no match or no entry. The
    /// matching entry need not be `active` -- recovery codes work even
    /// after a successful enrollment, which is the whole point.
    func useRecoveryCode(user: String, code: String) throws -> Bool {
        guard let idx = envelope.entries.firstIndex(where: { $0.name == user }) else {
            return false
        }
        let normalised = Self.normaliseRecoveryCode(code)
        let hash = Self.sha256Hex(normalised)
        guard let pos = envelope.entries[idx].recoveryHashes.firstIndex(of: hash) else {
            return false
        }
        envelope.entries[idx].recoveryHashes.remove(at: pos)
        try Self.persist(envelope, to: storePath)
        return true
    }

    /// Wipe a user's TOTP entry. Returns true if anything was removed.
    @discardableResult
    func disable(user: String) throws -> Bool {
        let before = envelope.entries.count
        envelope.entries.removeAll(where: { $0.name == user })
        if envelope.entries.count != before {
            try Self.persist(envelope, to: storePath)
            return true
        }
        return false
    }

    // MARK: - Internals

    private func entry(_ user: String) -> Entry? {
        envelope.entries.first(where: { $0.name == user })
    }

    private static func persist(_ env: Envelope, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(env) }
        catch { throw StoreError.ioFailed("encode: \(error)") }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("totp.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
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

    // MARK: - Crypto / encoding helpers (internal, but `static` so they
    // can be unit-tested without spinning up an actor).

    /// CSPRNG bytes. Uses `SystemRandomNumberGenerator`, which is
    /// CSPRNG-backed on every platform we target (BCryptGenRandom on
    /// Windows, getrandom on Linux, arc4random on Apple).
    static func randomBytes(_ count: Int) -> Data {
        var out = Data(count: count)
        out.withUnsafeMutableBytes { buf in
            var rng = SystemRandomNumberGenerator()
            var i = 0
            let bytes = buf.bindMemory(to: UInt8.self)
            while i < count {
                let r = rng.next()
                for b in 0..<8 where i < count {
                    bytes[i] = UInt8((r >> (b * 8)) & 0xFF)
                    i += 1
                }
            }
        }
        return out
    }

    static func randomRecoveryCode() -> String {
        // 10-hex-char codes (~40 bits entropy) -- presented to the user
        // with a dash for readability. Stored hashed.
        let bytes = randomBytes(5)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        // "abcd-efghij"
        let head = hex.prefix(4)
        let tail = hex.suffix(6)
        return "\(head)-\(tail)"
    }

    /// Lowercase, strip dashes/spaces. Recovery codes are matched
    /// loosely so users can paste them with or without separators.
    static func normaliseRecoveryCode(_ s: String) -> String {
        s.lowercased().filter { $0 != "-" && !$0.isWhitespace }
    }

    static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 4648 base32 encode, no padding. Used for both the on-disk
    /// secret and the otpauth URI -- TOTP apps mandate base32 secrets.
    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var buffer: UInt64 = 0
        var bitsLeft: Int = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let idx = Int((buffer >> UInt64(bitsLeft - 5)) & 0x1F)
                out.append(alphabet[idx])
                bitsLeft -= 5
            }
        }
        if bitsLeft > 0 {
            let idx = Int((buffer << UInt64(5 - bitsLeft)) & 0x1F)
            out.append(alphabet[idx])
        }
        return out
    }

    /// RFC 4648 base32 decode, padding-tolerant, case-insensitive.
    /// Returns nil for any non-alphabet character.
    static func base32Decode(_ s: String) -> Data? {
        let cleaned = s.uppercased().filter { $0 != "=" && !$0.isWhitespace }
        let alphabet: [Character: UInt8] = {
            var m: [Character: UInt8] = [:]
            for (i, c) in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567").enumerated() {
                m[c] = UInt8(i)
            }
            return m
        }()
        var buffer: UInt64 = 0
        var bitsLeft: Int = 0
        var out = Data()
        for c in cleaned {
            guard let v = alphabet[c] else { return nil }
            buffer = (buffer << 5) | UInt64(v)
            bitsLeft += 5
            if bitsLeft >= 8 {
                let byte = UInt8((buffer >> UInt64(bitsLeft - 8)) & 0xFF)
                out.append(byte)
                bitsLeft -= 8
            }
        }
        return out
    }

    /// RFC 6238 TOTP: SHA-1, 30-second step, 6 digits. Caller supplies
    /// the absolute time so tests can pin `at`.
    static func generateTotp(base32Secret: String, at date: Date, step: TimeInterval = 30, digits: Int = 6) -> String? {
        guard let key = base32Decode(base32Secret) else { return nil }
        let t = UInt64(floor(date.timeIntervalSince1970 / step))
        return hotp(key: key, counter: t, digits: digits)
    }

    /// Verify with +/- 1 step skew (90 s total acceptance window).
    static func verifyTotp(base32Secret: String, code: String, at date: Date, step: TimeInterval = 30, digits: Int = 6) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == digits, Int(trimmed) != nil else { return false }
        guard let key = base32Decode(base32Secret) else { return false }
        let t = UInt64(floor(date.timeIntervalSince1970 / step))
        for delta: Int64 in [-1, 0, 1] {
            let counter = UInt64(max(0, Int64(t) + delta))
            if hotp(key: key, counter: counter, digits: digits) == trimmed {
                return true
            }
        }
        return false
    }

    private static func hotp(key: Data, counter: UInt64, digits: Int) -> String {
        var be = counter.bigEndian
        let counterData = withUnsafeBytes(of: &be) { Data($0) }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterData,
            using: SymmetricKey(data: key)
        )
        let macBytes = Array(mac)
        let offset = Int(macBytes[macBytes.count - 1] & 0x0F)
        let p = (UInt32(macBytes[offset]     & 0x7F) << 24)
              | (UInt32(macBytes[offset + 1] & 0xFF) << 16)
              | (UInt32(macBytes[offset + 2] & 0xFF) << 8)
              |  UInt32(macBytes[offset + 3] & 0xFF)
        let modulus = UInt32(pow(10.0, Double(digits)))
        let truncated = p % modulus
        return String(format: "%0\(digits)u", truncated)
    }

    /// otpauth://totp/<issuer>:<account>?secret=<base32>&issuer=<issuer>&algorithm=SHA1&digits=6&period=30
    static func otpauthURI(issuer: String, account: String, base32Secret: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/?#"))
        func esc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let label = "\(esc(issuer)):\(esc(account))"
        return "otpauth://totp/\(label)?secret=\(base32Secret)&issuer=\(esc(issuer))&algorithm=SHA1&digits=6&period=30"
    }
}
