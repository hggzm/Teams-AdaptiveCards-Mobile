import Foundation

/// Phase 29 — HyperLogLog (PFADD / PFCOUNT / PFMERGE).
///
/// swiftka stores each HLL as a 12 304-byte blob in the existing
/// `rstring` table. Wire shape:
///
///     bytes 0..3   : magic "SHLL"
///     bytes 4..15  : reserved (zeros)
///     bytes 16..16303 : 16 384 × 6-bit packed registers
///
/// We use P = 14, so M = 2^14 = 16 384 buckets. Top 14 bits of the 64-bit
/// element hash pick the bucket; the count-of-leading-zeros + 1 of the
/// remaining 50 bits is the register value (capped at 51). Cardinality
/// is estimated with the canonical HLL formula plus the small-range
/// linear-counting correction. Hash is `MurmurHash64A` with the same
/// seed as Redis (0xadc83b19) so swiftka and a Redis instance hashing
/// the same data converge on the same bucket layout — useful when
/// comparing PFCOUNT results across the two implementations.
public enum HLL {
    public static let magic: [UInt8] = Array("SHLL".utf8)
    public static let headerBytes = 16
    public static let p = 14
    public static let m = 1 << 14         // 16 384
    public static let registerBytes = (m * 6 + 7) / 8   // 12 288
    public static let blobBytes = headerBytes + registerBytes
    public static let seed: UInt64 = 0xadc8_3b19

    /// True if `data` carries swiftka's HLL magic. Used as a type guard
    /// before treating an `rstring` value as an HLL container.
    public static func isHLL(_ data: Data) -> Bool {
        guard data.count == blobBytes else { return false }
        for i in 0..<magic.count where data[i] != magic[i] { return false }
        return true
    }

    /// Builds an empty HLL blob: magic header followed by 12 288 zero
    /// register bytes.
    public static func empty() -> Data {
        var d = Data(count: blobBytes)
        for i in 0..<magic.count { d[i] = magic[i] }
        return d
    }

    /// 64-bit MurmurHash2 (MurmurHash64A) — the same hash function and
    /// seed Redis uses for HLL.
    public static func murmur64(_ bytes: [UInt8], seed: UInt64 = seed) -> UInt64 {
        let m: UInt64 = 0xc6a4_a793_5bd1_e995
        let r: UInt64 = 47
        var h = seed ^ (UInt64(bytes.count) &* m)
        let nblocks = bytes.count / 8
        bytes.withUnsafeBufferPointer { buf in
            for i in 0..<nblocks {
                let base = i * 8
                var k: UInt64 = UInt64(buf[base])
                k |= UInt64(buf[base + 1]) << 8
                k |= UInt64(buf[base + 2]) << 16
                k |= UInt64(buf[base + 3]) << 24
                k |= UInt64(buf[base + 4]) << 32
                k |= UInt64(buf[base + 5]) << 40
                k |= UInt64(buf[base + 6]) << 48
                k |= UInt64(buf[base + 7]) << 56
                k = k &* m
                k ^= k >> r
                k = k &* m
                h ^= k
                h = h &* m
            }
            let tail = nblocks * 8
            let rem = bytes.count - tail
            if rem >= 7 { h ^= UInt64(buf[tail + 6]) << 48 }
            if rem >= 6 { h ^= UInt64(buf[tail + 5]) << 40 }
            if rem >= 5 { h ^= UInt64(buf[tail + 4]) << 32 }
            if rem >= 4 { h ^= UInt64(buf[tail + 3]) << 24 }
            if rem >= 3 { h ^= UInt64(buf[tail + 2]) << 16 }
            if rem >= 2 { h ^= UInt64(buf[tail + 1]) << 8 }
            if rem >= 1 {
                h ^= UInt64(buf[tail])
                h = h &* m
            }
        }
        h ^= h >> r
        h = h &* m
        h ^= h >> r
        return h
    }

    /// Pick the bucket index and register value for the next observation
    /// of `bytes`.
    public static func index(_ bytes: [UInt8]) -> (bucket: Int, value: UInt8) {
        let h = murmur64(bytes)
        let bucket = Int(h >> UInt64(64 - p))
        // Remaining 50 bits: count leading zeros, +1, cap at 51.
        let remaining = h & ((UInt64(1) << UInt64(64 - p)) - 1)
        // Move the remaining 50 bits into the high end of a 64-bit word
        // so leadingZeroBitCount counts correctly.
        let shifted = remaining << UInt64(p)
        let lz: Int
        if shifted == 0 {
            lz = 64 - p
        } else {
            // CLZ on the shifted value, but cap counting at (64 - p)
            // since we only care about the bits we shifted in.
            let raw = shifted.leadingZeroBitCount
            lz = min(raw, 64 - p)
        }
        let v = UInt8(min(lz + 1, 50))
        return (bucket, v)
    }

    /// Read the 6-bit register at index `i` from a 12 304-byte HLL blob.
    public static func getRegister(_ blob: Data, _ i: Int) -> UInt8 {
        let bitPos = i * 6
        let bytePos = headerBytes + bitPos / 8
        let bitShift = bitPos % 8
        // 6 bits may straddle two consecutive bytes.
        let b0 = UInt16(blob[bytePos])
        let b1: UInt16 = (bytePos + 1) < blob.count ? UInt16(blob[bytePos + 1]) : 0
        let combined = b0 | (b1 << 8)
        return UInt8((combined >> bitShift) & 0x3F)
    }

    /// Write the 6-bit register at index `i` into `blob`. The caller
    /// owns the storage lifecycle (blob must be at least `blobBytes`
    /// long).
    public static func setRegister(_ blob: inout Data, _ i: Int, _ value: UInt8) {
        let v = UInt16(value & 0x3F)
        let bitPos = i * 6
        let bytePos = headerBytes + bitPos / 8
        let bitShift = bitPos % 8
        let mask: UInt16 = 0x3F << bitShift
        let b0 = UInt16(blob[bytePos])
        let b1: UInt16 = (bytePos + 1) < blob.count ? UInt16(blob[bytePos + 1]) : 0
        var combined = b0 | (b1 << 8)
        combined &= ~mask
        combined |= v << bitShift
        blob[bytePos] = UInt8(combined & 0xFF)
        if (bytePos + 1) < blob.count {
            blob[bytePos + 1] = UInt8((combined >> 8) & 0xFF)
        }
    }

    /// Cardinality estimate using the canonical HLL formula with the
    /// small-range linear-counting correction (no large-range
    /// correction — modern 64-bit hashes don't need it).
    public static func cardinality(_ blob: Data) -> Int {
        let mD = Double(m)
        // alpha_m for m = 16384.
        let alpha = 0.7213 / (1 + 1.079 / mD)
        var sum = 0.0
        var zeros = 0
        for i in 0..<m {
            let r = getRegister(blob, i)
            if r == 0 { zeros += 1 }
            sum += 1.0 / Double(UInt64(1) << UInt64(r))
        }
        let estimate = alpha * mD * mD / sum
        // Small-range linear-counting correction.
        if estimate <= 2.5 * mD, zeros > 0 {
            return Int(round(mD * log(mD / Double(zeros))))
        }
        return Int(round(estimate))
    }
}

extension KeyStore {

    /// `PFADD key [element ...]`. Returns 1 if any register changed,
    /// 0 otherwise. Auto-creates an empty HLL blob if the key is
    /// missing. Throws WRONGTYPE if the key holds a string that
    /// doesn't carry the SHLL magic, or a non-string value.
    @discardableResult
    public func pfAdd(key: String, elements: [Data]) throws -> Int {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                var blob: Data
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing:
                    try Self.upsertKeyLocked(conn: conn, key: key, type: .string)
                    blob = HLL.empty()
                case .wrongType:
                    try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                case .value(let v):
                    if HLL.isHLL(v) {
                        blob = v
                    } else {
                        try conn.exec("ROLLBACK")
                        throw KeyStoreError.appError("WRONGTYPE Key is not a valid HyperLogLog string value.")
                    }
                }
                var changed = false
                for elem in elements {
                    let bytes = [UInt8](elem)
                    let (bucket, v) = HLL.index(bytes)
                    let current = HLL.getRegister(blob, bucket)
                    if v > current {
                        HLL.setRegister(&blob, bucket, v)
                        changed = true
                    }
                }
                if changed || !elements.isEmpty {
                    // Always write through when we materialized a blob
                    // for a previously-missing key, even if no register
                    // moved (Redis returns 1 in that case too).
                }
                if changed {
                    let kid = try Self.fetchKidLocked(conn: conn, key: key)
                    try conn.run(
                        "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                        bind: { stmt in
                            SQLiteConnection.bindInt64(stmt, 1, kid)
                            SQLiteConnection.bindBlob(stmt, 2, blob)
                        },
                        rowMap: { _ in () }
                    )
                } else {
                    // Newly-created empty key — still persist the empty
                    // blob so PFCOUNT on the key returns 0 rather than
                    // failing the HLL type guard.
                    let kid = try Self.fetchKidLocked(conn: conn, key: key)
                    let exists: [Int64] = try conn.run(
                        "SELECT 1 FROM rstring WHERE kid = ?",
                        bind: { stmt in SQLiteConnection.bindInt64(stmt, 1, kid) },
                        rowMap: { _ in 1 }
                    )
                    if exists.isEmpty {
                        try conn.run(
                            "INSERT INTO rstring (kid, value) VALUES (?, ?)",
                            bind: { stmt in
                                SQLiteConnection.bindInt64(stmt, 1, kid)
                                SQLiteConnection.bindBlob(stmt, 2, blob)
                            },
                            rowMap: { _ in () }
                        )
                    }
                }
                try conn.exec("COMMIT")
                return changed ? 1 : 0
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// `PFCOUNT key [key ...]`. Single-key path returns that key's
    /// cardinality; multi-key path returns the cardinality of the
    /// union (computed by max-merging the register arrays). Missing
    /// keys count as empty HLLs.
    public func pfCount(keys: [String]) throws -> Int {
        try database.withLock { conn in
            if keys.count == 1 {
                switch try Self.fetchStringValueLocked(conn: conn, key: keys[0]) {
                case .missing:      return 0
                case .wrongType:    throw KeyStoreError.wrongType
                case .value(let v):
                    if HLL.isHLL(v) { return HLL.cardinality(v) }
                    throw KeyStoreError.appError("WRONGTYPE Key is not a valid HyperLogLog string value.")
                }
            }
            var merged = HLL.empty()
            for key in keys {
                switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                case .missing: continue
                case .wrongType: throw KeyStoreError.wrongType
                case .value(let v):
                    if !HLL.isHLL(v) {
                        throw KeyStoreError.appError("WRONGTYPE Key is not a valid HyperLogLog string value.")
                    }
                    for i in 0..<HLL.m {
                        let a = HLL.getRegister(merged, i)
                        let b = HLL.getRegister(v, i)
                        if b > a { HLL.setRegister(&merged, i, b) }
                    }
                }
            }
            return HLL.cardinality(merged)
        }
    }

    /// `PFMERGE dest source [source ...]`. Max-merges register arrays
    /// from every existing source (missing sources are skipped) plus
    /// the destination's current contents into `dest`. Always returns
    /// OK (mirrors Redis).
    public func pfMerge(dest: String, sources: [String]) throws {
        try database.withLock { conn in
            try conn.exec("BEGIN IMMEDIATE")
            do {
                var merged: Data
                switch try Self.fetchStringValueLocked(conn: conn, key: dest) {
                case .missing:
                    merged = HLL.empty()
                case .wrongType:
                    try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                case .value(let v):
                    if HLL.isHLL(v) {
                        merged = v
                    } else {
                        try conn.exec("ROLLBACK")
                        throw KeyStoreError.appError("WRONGTYPE Key is not a valid HyperLogLog string value.")
                    }
                }
                for key in sources {
                    switch try Self.fetchStringValueLocked(conn: conn, key: key) {
                    case .missing: continue
                    case .wrongType:
                        try conn.exec("ROLLBACK"); throw KeyStoreError.wrongType
                    case .value(let v):
                        if !HLL.isHLL(v) {
                            try conn.exec("ROLLBACK")
                            throw KeyStoreError.appError("WRONGTYPE Key is not a valid HyperLogLog string value.")
                        }
                        for i in 0..<HLL.m {
                            let a = HLL.getRegister(merged, i)
                            let b = HLL.getRegister(v, i)
                            if b > a { HLL.setRegister(&merged, i, b) }
                        }
                    }
                }
                try Self.upsertKeyLocked(conn: conn, key: dest, type: .string)
                let kid = try Self.fetchKidLocked(conn: conn, key: dest)
                try conn.run(
                    "INSERT INTO rstring (kid, value) VALUES (?, ?) ON CONFLICT(kid) DO UPDATE SET value = excluded.value",
                    bind: { stmt in
                        SQLiteConnection.bindInt64(stmt, 1, kid)
                        SQLiteConnection.bindBlob(stmt, 2, merged)
                    },
                    rowMap: { _ in () }
                )
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }
}
