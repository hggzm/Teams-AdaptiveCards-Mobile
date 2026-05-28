import Foundation

/// Phase 31 — Redis EVAL / SCRIPT / EVALSHA.
///
/// swiftka does **not** ship a real Lua VM. Instead, `ScriptEngine`
/// recognises a narrow set of script shapes that account for the vast
/// majority of real-world Redis Lua usage:
///
/// - `return <literal>` where literal is a Lua number, single/double
///   quoted string, `nil`, `true`, `false`, or an array constructor
///   `{ ..., ..., ... }`.
/// - `return KEYS[N]` / `return ARGV[N]` (1-based, matches Lua / Redis).
/// - `return redis.call('CMD', argN, ...)` and
///   `return redis.pcall(...)` — the common one-command wrapper.
/// - `return tonumber(KEYS[1]) + tonumber(ARGV[1])` — recognised as
///   "add two integer args" so cardinality probes that send the
///   classic Redis demo script still work.
///
/// Scripts that don't match any pattern return the Redis-canonical
/// `ERR ...` error. The wire reply for matched scripts is honest to
/// the Lua → RESP conversion rules (numbers → integer, strings →
/// bulk, nil → nil bulk, tables → array, etc).
public final class ScriptStore: @unchecked Sendable {

    private let lock = NSLock()
    /// SHA-1 → script source. Persistent across the process lifetime
    /// (and cleared by SCRIPT FLUSH).
    private var scripts: [String: String] = [:]

    public init() {}

    /// Hashes `source` with SHA-1 (Redis-canonical) and registers it.
    /// Returns the 40-char lowercase hex digest.
    @discardableResult
    public func load(_ source: String) -> String {
        let sha = Self.sha1Hex(source)
        lock.lock(); defer { lock.unlock() }
        scripts[sha] = source
        return sha
    }

    /// Returns the source previously registered under `sha`, or `nil`
    /// when EVALSHA is given a digest the server never saw.
    public func source(for sha: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return scripts[sha.lowercased()]
    }

    /// Returns the same array EVAL / SCRIPT EXISTS uses: 1 if the
    /// digest is registered, 0 otherwise (in the order asked).
    public func exists(_ shas: [String]) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return shas.map { scripts[$0.lowercased()] != nil ? 1 : 0 }
    }

    /// Wipes every registered script.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        scripts.removeAll()
    }

    // MARK: - SHA-1 (RFC 3174 / FIPS 180-4)
    //
    // 20-byte digest formatted as a lowercase hex string (Redis script
    // hashes are always 40 lowercase hex chars).

    public static func sha1Hex(_ s: String) -> String {
        let bytes = [UInt8](s.utf8)
        let digest = sha1(bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(_ data: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

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
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let o = base + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16) |
                       (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
            }
            for i in 16..<80 {
                let v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (v << 1) | (v >> 31)
            }
            var a = h0, bb = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20:  f = (bb & c) | (~bb & d); k = 0x5A827999
                case 20..<40: f = bb ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (bb & c) | (bb & d) | (c & d); k = 0x8F1BBCDC
                default:      f = bb ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (bb << 30) | (bb >> 2)
                bb = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ bb
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }
        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }
}

/// Narrow Lua-shape evaluator. `evaluate` returns a fully-resolved
/// `RESPValue` ready to ship on the wire. Recursion into the dispatcher
/// (for `redis.call`) is performed via the caller-supplied `dispatch`
/// closure so this struct remains independent of `CommandDispatcher`.
public struct ScriptEngine {

    /// Recursive dispatch closure that runs a single Redis command
    /// inside the script context. Caller wires this to the same
    /// `CommandDispatcher.dispatchRaw` it uses elsewhere.
    public typealias Dispatch = (RESPCommand) -> RESPValue

    public let dispatch: Dispatch

    public init(dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    /// Evaluates `source` with the given KEYS / ARGV bindings.
    /// Returns the script's RESP reply.
    public func evaluate(_ source: String, keys: [String], argv: [String]) -> RESPValue {
        // Strip line comments (`-- foo`) and surrounding whitespace
        // before pattern-matching. Real Lua tokenisation isn't worth
        // the bytes for this narrow surface.
        var body = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped: String
            if let r = line.range(of: "--") {
                stripped = String(line[..<r.lowerBound])
            } else {
                stripped = String(line)
            }
            body += stripped + "\n"
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("return ") else {
            return .error("ERR script not supported by swiftka's narrow evaluator")
        }
        let expr = String(trimmed.dropFirst("return ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return evaluateExpression(expr, keys: keys, argv: argv)
    }

    private func evaluateExpression(_ raw: String, keys: [String], argv: [String]) -> RESPValue {
        let expr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if expr.isEmpty { return .bulkString(nil) }
        if expr == "nil" { return .bulkString(nil) }
        if expr == "true" { return .integer(1) }
        if expr == "false" { return .bulkString(nil) }
        // Integer / float literal.
        if let n = Int64(expr) { return .integer(n) }
        if let _ = Double(expr) {
            // Lua-to-RESP conversion truncates floats to integers per
            // Redis (the float is silently truncated). Match that.
            if let d = Double(expr) {
                return .integer(Int64(d))
            }
        }
        // Quoted string literal: single or double quotes.
        if (expr.hasPrefix("'") && expr.hasSuffix("'")) ||
           (expr.hasPrefix("\"") && expr.hasSuffix("\"")), expr.count >= 2 {
            let s = String(expr.dropFirst().dropLast())
            return .bulkString(s)
        }
        // KEYS[<n>] / ARGV[<n>].
        if let v = arrayAccess(expr, name: "KEYS", values: keys) { return v }
        if let v = arrayAccess(expr, name: "ARGV", values: argv) { return v }
        // Tables: { e1, e2, ... }.
        if expr.hasPrefix("{") && expr.hasSuffix("}") {
            let inner = String(expr.dropFirst().dropLast())
            let parts = splitTopLevel(inner, by: ",")
            let resolved = parts.map { evaluateExpression($0, keys: keys, argv: argv) }
            return .array(resolved)
        }
        // redis.call(...) / redis.pcall(...).
        if let v = redisCall(expr, keys: keys, argv: argv) { return v }
        // tonumber(KEYS[1]) + tonumber(ARGV[1]) — the canonical
        // "add two integer arguments" cardinality demo.
        if let v = tonumberAdd(expr, keys: keys, argv: argv) { return v }
        // #KEYS / #ARGV — length operator.
        if expr == "#KEYS" { return .integer(Int64(keys.count)) }
        if expr == "#ARGV" { return .integer(Int64(argv.count)) }
        return .error("ERR script not supported by swiftka's narrow evaluator")
    }

    /// Matches `<name>[<index>]` where index is 1-based. Returns the
    /// referenced value as a bulk string, or `nil` for out-of-range
    /// indexing (matches Lua's "no value" semantics).
    private func arrayAccess(_ expr: String, name: String, values: [String]) -> RESPValue? {
        let prefix = name + "["
        guard expr.hasPrefix(prefix), expr.hasSuffix("]") else { return nil }
        let inside = String(expr.dropFirst(prefix.count).dropLast())
        guard let idx = Int(inside.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        guard idx >= 1, idx <= values.count else { return .bulkString(nil) }
        return .bulkString(values[idx - 1])
    }

    /// Match `redis.call('CMD', ...)` or `redis.pcall('CMD', ...)`. Args
    /// can be string literals, KEYS[i] / ARGV[i] references, or numeric
    /// literals. Returns the dispatched command's RESP reply.
    private func redisCall(_ expr: String, keys: [String], argv: [String]) -> RESPValue? {
        for prefix in ["redis.call(", "redis.pcall("] {
            guard expr.hasPrefix(prefix), expr.hasSuffix(")") else { continue }
            let inside = String(expr.dropFirst(prefix.count).dropLast())
            let parts = splitTopLevel(inside, by: ",")
            guard !parts.isEmpty else { return .error("ERR redis.call requires a command name") }
            var argBytes: [Data] = []
            var cmdName: String? = nil
            for (i, part) in parts.enumerated() {
                let pTrim = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let v = evaluateExpression(pTrim, keys: keys, argv: argv)
                let text: String
                switch v {
                case .bulkString(.some(let d)):
                    text = String(data: d, encoding: .utf8) ?? ""
                case .bulkString(.none):
                    text = ""
                case .simpleString(let s):
                    text = s
                case .integer(let n):
                    text = String(n)
                default:
                    return .error("ERR redis.call: argument must be a string or number")
                }
                if i == 0 {
                    cmdName = text.uppercased()
                } else {
                    argBytes.append(Data(text.utf8))
                }
            }
            guard let name = cmdName else { return .error("ERR missing command name") }
            return dispatch(RESPCommand(name: name, args: argBytes))
        }
        return nil
    }

    /// Match the canonical
    /// `tonumber(KEYS[1]) + tonumber(ARGV[1])` shape, returning an
    /// integer sum. Generalised slightly to accept either ordering and
    /// either index.
    private func tonumberAdd(_ expr: String, keys: [String], argv: [String]) -> RESPValue? {
        // Very narrow regex: <tonumber(.+)> <op> <tonumber(.+)>
        // where op is + or -. Avoids pulling in a real parser.
        guard expr.contains("tonumber("), expr.contains("+") || expr.contains("-") else {
            return nil
        }
        // Tokenise on +/- at depth 0.
        var depth = 0
        var split: Int? = nil
        var opChar: Character = "+"
        for (i, ch) in expr.enumerated() {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1 }
            else if depth == 0 && (ch == "+" || ch == "-") && i > 0 {
                split = i; opChar = ch; break
            }
        }
        guard let idx = split else { return nil }
        let lhs = String(expr.prefix(idx)).trimmingCharacters(in: .whitespaces)
        let rhs = String(expr.suffix(from: expr.index(expr.startIndex, offsetBy: idx + 1))).trimmingCharacters(in: .whitespaces)
        func numericValue(_ inner: String) -> Int64? {
            var s = inner
            if s.hasPrefix("tonumber("), s.hasSuffix(")") {
                s = String(s.dropFirst("tonumber(".count).dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }
            switch evaluateExpression(s, keys: keys, argv: argv) {
            case .integer(let n): return n
            case .bulkString(.some(let d)):
                return String(data: d, encoding: .utf8).flatMap { Int64($0) }
            default: return nil
            }
        }
        guard let a = numericValue(lhs), let b = numericValue(rhs) else { return nil }
        return .integer(opChar == "+" ? a &+ b : a &- b)
    }

    /// Split `s` by `sep` at the top nesting level (depth 0) — keeps
    /// `{1, 2}` together when the surrounding separator is also `,`.
    private func splitTopLevel(_ s: String, by sep: Character) -> [String] {
        var depth = 0
        var current = ""
        var out: [String] = []
        var inSingle = false
        var inDouble = false
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); continue }
            if !inSingle && !inDouble {
                if ch == "(" || ch == "{" || ch == "[" { depth += 1 }
                else if ch == ")" || ch == "}" || ch == "]" { depth -= 1 }
                else if ch == sep && depth == 0 {
                    out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { out.append(last) }
        return out
    }
}
