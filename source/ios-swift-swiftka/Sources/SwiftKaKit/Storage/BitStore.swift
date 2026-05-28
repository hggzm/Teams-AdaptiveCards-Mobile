import Csqlite3
import Foundation

/// Phase 27 — bit-level string operations.
///
/// SETBIT / GETBIT operate on individual bits in the byte string stored
/// at a key. BITCOUNT / BITPOS scan a range (in bytes or bits) of a
/// string. BITOP composes a fresh value from one or more source strings
/// using a bitwise operator (AND / OR / XOR / NOT). BITFIELD packs the
/// above into a transactional batch — multiple GET/SET/INCRBY operations
/// on sub-byte integer fields in a single round trip, with three
/// overflow modes (WRAP / SAT / FAIL).
///
/// All ops live on the existing `rstring` table; no schema change.
extension KeyStore {

    // MARK: - SETBIT / GETBIT

    /// Sets the bit at `offset` (0-based, big-endian within a byte) to
    /// 0 or 1; returns the previous bit value. Auto-extends the string
    /// with zero bytes if `offset` runs past the current length.
    public func setBit(key: String, offset: Int, value: Int) throws -> Int {
        guard offset >= 0 else { throw KeyStoreError.appError("ERR bit offset is not an integer or out of range") }
        guard value == 0 || value == 1 else { throw KeyStoreError.appError("ERR bit is not an integer or out of range") }
        return try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let existing = try Self.fetchStringValueLocked(conn: conn, key: key)
                var bytes: Data
                switch existing {
                case .missing:
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    bytes = Data()
                case .wrongType:
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                case .value(let v):
                    bytes = v
                }
                let byteIndex = offset / 8
                let bitInByte = 7 - (offset % 8)
                if bytes.count <= byteIndex {
                    bytes.append(Data(repeating: 0, count: byteIndex + 1 - bytes.count))
                }
                let mask: UInt8 = 1 << bitInByte
                let previous: Int = (bytes[byteIndex] & mask) != 0 ? 1 : 0
                if value == 1 {
                    bytes[byteIndex] |= mask
                } else {
                    bytes[byteIndex] &= ~mask
                }
                let kid = try Self.fetchKidLocked(conn: conn, key: key)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, bytes)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
                return previous
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Reads a single bit at `offset`. Returns 0 for missing keys or
    /// offsets past the end of the string.
    public func getBit(key: String, offset: Int) throws -> Int {
        guard offset >= 0 else { throw KeyStoreError.appError("ERR bit offset is not an integer or out of range") }
        return try database.withLock { conn in
            switch try Self.fetchStringValueLocked(conn: conn, key: key) {
            case .missing:      return 0
            case .wrongType:    throw KeyStoreError.wrongType
            case .value(let v):
                let byteIndex = offset / 8
                let bitInByte = 7 - (offset % 8)
                if byteIndex >= v.count { return 0 }
                return (v[byteIndex] & (1 << bitInByte)) != 0 ? 1 : 0
            }
        }
    }

    // MARK: - BITCOUNT

    /// Unit used by BITCOUNT / BITPOS range arguments.
    public enum BitRangeUnit: Sendable { case byte, bit }

    /// Counts set bits in [start, end] (inclusive) within either bytes
    /// or bits. Negative indices count from the end. Missing keys
    /// return 0.
    public func bitCount(key: String, start: Int? = nil, end: Int? = nil,
                         unit: BitRangeUnit = .byte) throws -> Int {
        try database.withLock { conn in
            switch try Self.fetchStringValueLocked(conn: conn, key: key) {
            case .missing:      return 0
            case .wrongType:    throw KeyStoreError.wrongType
            case .value(let v):
                let totalBits = v.count * 8
                let totalUnits = unit == .byte ? v.count : totalBits
                guard totalUnits > 0 else { return 0 }
                var lo = start ?? 0
                var hi = end ?? (totalUnits - 1)
                if lo < 0 { lo = max(0, totalUnits + lo) }
                if hi < 0 { hi = totalUnits + hi }
                lo = max(0, lo)
                hi = min(totalUnits - 1, hi)
                if lo > hi { return 0 }
                // Convert to bit range.
                let bitLo = unit == .byte ? lo * 8 : lo
                let bitHi = unit == .byte ? hi * 8 + 7 : hi
                var count = 0
                for bit in bitLo...bitHi {
                    let byteIndex = bit / 8
                    let bitInByte = 7 - (bit % 8)
                    if byteIndex < v.count, (v[byteIndex] & (1 << bitInByte)) != 0 {
                        count += 1
                    }
                }
                return count
            }
        }
    }

    // MARK: - BITPOS

    /// Returns the position of the first bit equal to `target` (0 or 1)
    /// within an optional [start, end] range (bytes or bits). Returns
    /// -1 if no such bit exists in the range. For target=0 with no
    /// explicit end and the value ending in all-0xFF bytes, returns
    /// the first bit past the end (Redis quirk).
    public func bitPos(key: String, target: Int,
                       start: Int? = nil, end: Int? = nil,
                       unit: BitRangeUnit = .byte) throws -> Int {
        guard target == 0 || target == 1 else { throw KeyStoreError.appError("ERR The bit argument must be 1 or 0.") }
        return try database.withLock { conn in
            switch try Self.fetchStringValueLocked(conn: conn, key: key) {
            case .missing:
                // Empty string: target=0 → 0, target=1 → -1.
                return target == 0 ? 0 : -1
            case .wrongType:
                throw KeyStoreError.wrongType
            case .value(let v):
                let totalBits = v.count * 8
                let totalUnits = unit == .byte ? v.count : totalBits
                if totalUnits == 0 {
                    return target == 0 ? 0 : -1
                }
                let endExplicit = end != nil
                var lo = start ?? 0
                var hi = end ?? (totalUnits - 1)
                if lo < 0 { lo = max(0, totalUnits + lo) }
                if hi < 0 { hi = totalUnits + hi }
                lo = max(0, lo)
                hi = min(totalUnits - 1, hi)
                if lo > hi { return -1 }
                let bitLo = unit == .byte ? lo * 8 : lo
                let bitHi = unit == .byte ? hi * 8 + 7 : hi
                for bit in bitLo...bitHi {
                    let byteIndex = bit / 8
                    let bitInByte = 7 - (bit % 8)
                    let bitVal = byteIndex < v.count
                        ? ((v[byteIndex] & (1 << bitInByte)) != 0 ? 1 : 0)
                        : 0
                    if bitVal == target { return bit }
                }
                // Redis quirk: looking for clear bit (0) without an
                // explicit end argument returns the position just past
                // the end if all scanned bits are 1.
                if target == 0 && !endExplicit { return bitHi + 1 }
                return -1
            }
        }
    }

    // MARK: - BITOP

    public enum BitOp: Sendable { case and, or, xor, not }

    /// Performs the bitwise operator across `sources` and writes the
    /// result to `dest`. NOT requires exactly one source. Result length
    /// is the length of the longest source; shorter sources are
    /// zero-padded. Returns the final length of `dest`. Missing source
    /// keys are treated as empty strings.
    @discardableResult
    public func bitOp(_ op: BitOp, dest: String, sources: [String]) throws -> Int {
        switch op {
        case .not:
            guard sources.count == 1 else { throw KeyStoreError.appError("ERR BITOP NOT must be called with a single source key.") }
        default:
            guard !sources.isEmpty else { throw KeyStoreError.appError("ERR wrong number of arguments for 'bitop' command") }
        }
        return try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                // Fetch all source values up front (type-checked).
                var values: [Data] = []
                for k in sources {
                    switch try Self.fetchStringValueLocked(conn: conn, key: k) {
                    case .missing:      values.append(Data())
                    case .wrongType:    try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                    case .value(let v): values.append(v)
                    }
                }
                let maxLen = values.map(\.count).max() ?? 0
                var out = Data(count: maxLen)
                if op == .not {
                    let src = values[0]
                    for i in 0..<src.count {
                        out[i] = ~src[i]
                    }
                } else {
                    // Initialise with the first source padded to maxLen.
                    let first = values[0]
                    for i in 0..<maxLen {
                        out[i] = i < first.count ? first[i] : 0
                    }
                    for src in values.dropFirst() {
                        for i in 0..<maxLen {
                            let b: UInt8 = i < src.count ? src[i] : 0
                            switch op {
                            case .and: out[i] &= b
                            case .or:  out[i] |= b
                            case .xor: out[i] ^= b
                            case .not: break // unreachable
                            }
                        }
                    }
                }
                if maxLen == 0 {
                    // Empty result: delete the destination key.
                    try conn.run(
                        "DELETE FROM rkey WHERE key = ?",
                        bind: { stmt in SQLiteConnection.bindText(stmt, 1, dest) },
                        rowMap: { _ in () }
                    )
                } else {
                    // Type-guard dest if it already exists as a non-string.
                    switch try Self.fetchStringValueLocked(conn: conn, key: dest) {
                    case .wrongType:
                        try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                    case .missing, .value:
                        break
                    }
                    try Self.upsertKeyLocked(conn: conn, key: dest, type: .string)
                    let kid = try Self.fetchKidLocked(conn: conn, key: dest)
                    try conn.run(
                        "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, out)
                        },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return maxLen
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - BITFIELD

    /// Overflow behaviour for BITFIELD INCRBY / SET. WRAP is the
    /// default (signed two's-complement modular arithmetic). SAT
    /// saturates at min/max of the integer width. FAIL returns nil
    /// for any operation that would overflow.
    public enum BitFieldOverflow: Sendable { case wrap, sat, fail }

    /// Individual operation within a BITFIELD batch.
    public enum BitFieldOp: Sendable {
        case get(type: BitFieldType, offset: Int)
        case set(type: BitFieldType, offset: Int, value: Int64)
        case incrBy(type: BitFieldType, offset: Int, delta: Int64)
        case overflow(BitFieldOverflow)
    }

    /// Width + signedness of a BITFIELD integer field. Signed widths
    /// are 1..64; unsigned are 1..63 (matches Redis to keep round-trip
    /// shape).
    public struct BitFieldType: Sendable, Equatable {
        public let signed: Bool
        public let bits: Int
        public init(signed: Bool, bits: Int) {
            self.signed = signed
            self.bits = bits
        }
    }

    /// Runs a BITFIELD batch. Each emitted output corresponds to a
    /// GET / SET / INCRBY op (OVERFLOW emits nothing). Each output is
    /// either the integer result (Int64) or `nil` when an INCRBY/SET
    /// with OVERFLOW FAIL overflowed.
    public func bitField(key: String, ops: [BitFieldOp]) throws -> [Int64?] {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                var bytes: Data
                var keyExists = true
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing:
                    bytes = Data()
                    keyExists = false
                case .wrongType:
                    try conn.exec("ROLLBACK")
                    throw KeyStoreError.wrongType
                case .value(let v):
                    bytes = v
                }
                var overflow: BitFieldOverflow = .wrap
                var results: [Int64?] = []
                var dirty = false
                for op in ops {
                    switch op {
                    case .overflow(let mode):
                        overflow = mode
                    case .get(let type, let offset):
                        results.append(Self.bitFieldRead(bytes: bytes, type: type, offset: offset))
                    case .set(let type, let offset, let value):
                        if let applied = Self.bitFieldApplySet(value: value, type: type, overflow: overflow) {
                            let prev = Self.bitFieldRead(bytes: bytes, type: type, offset: offset)
                            Self.bitFieldWrite(bytes: &bytes, type: type, offset: offset, value: applied)
                            results.append(prev)
                            dirty = true
                        } else {
                            // Overflow FAIL: returns nil and skips write.
                            results.append(nil)
                        }
                    case .incrBy(let type, let offset, let delta):
                        let current = Self.bitFieldRead(bytes: bytes, type: type, offset: offset) ?? 0
                        if let next = Self.bitFieldApplyIncr(current: current, delta: delta, type: type, overflow: overflow) {
                            Self.bitFieldWrite(bytes: &bytes, type: type, offset: offset, value: next)
                            results.append(next)
                            dirty = true
                        } else {
                            results.append(nil)
                        }
                    }
                }
                if dirty {
                    if !keyExists {
                        try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    }
                    let kid = try Self.fetchKidLocked(conn: conn, key: key)
                    try conn.run(
                        "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, bytes)
                        },
                        rowMap: { _ in () }
                    )
                }
                try conn.exec("COMMIT")
                return results
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - BITFIELD internals (static, lockless — work on bytes copy)

    /// Reads a sub-byte integer field from `bytes`. Returns 0-extended
    /// for offsets past the buffer end. Always returns a value (never
    /// nil) — the optional return is reserved for callers that share
    /// the signature with the write variants.
    static func bitFieldRead(bytes: Data, type: BitFieldType, offset: Int) -> Int64 {
        var raw: UInt64 = 0
        for i in 0..<type.bits {
            let bit = offset + i
            let byteIndex = bit / 8
            let bitInByte = 7 - (bit % 8)
            let bitVal: UInt64 = byteIndex < bytes.count
                ? UInt64((bytes[byteIndex] >> bitInByte) & 1)
                : 0
            raw = (raw << 1) | bitVal
        }
        if !type.signed { return Int64(raw) }
        // Sign-extend.
        let signBit: UInt64 = 1 << (type.bits - 1)
        if (raw & signBit) != 0 {
            let mask: UInt64 = type.bits == 64 ? ~UInt64(0) : (~UInt64(0) << type.bits)
            return Int64(bitPattern: raw | mask)
        }
        return Int64(raw)
    }

    /// Writes a sub-byte integer field into `bytes`. Auto-extends if
    /// the write runs past the current length.
    static func bitFieldWrite(bytes: inout Data, type: BitFieldType, offset: Int, value: Int64) {
        let neededBytes = (offset + type.bits + 7) / 8
        if bytes.count < neededBytes {
            bytes.append(Data(repeating: 0, count: neededBytes - bytes.count))
        }
        let raw: UInt64
        if type.bits == 64 {
            raw = UInt64(bitPattern: value)
        } else {
            let mask: UInt64 = (UInt64(1) << type.bits) - 1
            raw = UInt64(bitPattern: value) & mask
        }
        for i in 0..<type.bits {
            let bit = offset + i
            let byteIndex = bit / 8
            let bitInByte = 7 - (bit % 8)
            let srcBit = UInt8((raw >> (type.bits - 1 - i)) & 1)
            let mask: UInt8 = 1 << bitInByte
            if srcBit == 1 {
                bytes[byteIndex] |= mask
            } else {
                bytes[byteIndex] &= ~mask
            }
        }
    }

    /// Applies overflow to a SET value, returning the stored value or
    /// nil when FAIL kicks in.
    static func bitFieldApplySet(value: Int64, type: BitFieldType, overflow: BitFieldOverflow) -> Int64? {
        let (lo, hi) = bitFieldRange(type: type)
        if value >= lo && value <= hi { return value }
        switch overflow {
        case .wrap: return bitFieldWrap(value: value, type: type)
        case .sat:  return value > hi ? hi : lo
        case .fail: return nil
        }
    }

    /// Applies overflow to an INCRBY result. Uses 128-bit-like
    /// reasoning by doing math in Int64 and checking against the
    /// type's valid range.
    static func bitFieldApplyIncr(current: Int64, delta: Int64, type: BitFieldType, overflow: BitFieldOverflow) -> Int64? {
        // Use overflow-aware arithmetic.
        let (raw, carry) = current.addingReportingOverflow(delta)
        let (lo, hi) = bitFieldRange(type: type)
        if !carry && raw >= lo && raw <= hi { return raw }
        switch overflow {
        case .wrap: return bitFieldWrap(value: raw, type: type)
        case .sat:
            if carry {
                return delta > 0 ? hi : lo
            }
            return raw > hi ? hi : lo
        case .fail: return nil
        }
    }

    /// Valid range for a BITFIELD integer type.
    static func bitFieldRange(type: BitFieldType) -> (lo: Int64, hi: Int64) {
        if type.signed {
            if type.bits == 64 {
                return (Int64.min, Int64.max)
            }
            let lo = -(Int64(1) << (type.bits - 1))
            let hi = (Int64(1) << (type.bits - 1)) - 1
            return (lo, hi)
        } else {
            let hi = type.bits == 63
                ? Int64.max
                : (Int64(1) << type.bits) - 1
            return (0, hi)
        }
    }

    /// Wraps `value` into the type's range by truncating to `bits` then
    /// sign-extending if signed.
    static func bitFieldWrap(value: Int64, type: BitFieldType) -> Int64 {
        let raw: UInt64
        if type.bits == 64 {
            raw = UInt64(bitPattern: value)
        } else {
            let mask: UInt64 = (UInt64(1) << type.bits) - 1
            raw = UInt64(bitPattern: value) & mask
        }
        if !type.signed { return Int64(raw) }
        let signBit: UInt64 = 1 << (type.bits - 1)
        if (raw & signBit) != 0 {
            let mask: UInt64 = type.bits == 64 ? ~UInt64(0) : (~UInt64(0) << type.bits)
            return Int64(bitPattern: raw | mask)
        }
        return Int64(raw)
    }
}
