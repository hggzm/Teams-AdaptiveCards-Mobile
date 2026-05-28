import Foundation

/// Phase 28 — Redis Geo commands.
///
/// Redis Geo is sorted-sets in disguise. A GEOADD stores each member
/// with a score equal to the 52-bit interleaved geohash of its
/// (longitude, latitude). All scans (GEOPOS / GEODIST / GEOSEARCH /
/// GEORADIUSBYMEMBER / GEOHASH) decode the score back to lat/lon and
/// then operate in the geographic plane.
///
/// Because Geo is just sorted-set storage, GEOADD writes directly to
/// the existing `rzset` table — no schema change.
public enum GeoUnit: String, Sendable, Equatable {
    case meters = "M"
    case kilometers = "KM"
    case miles = "MI"
    case feet = "FT"

    /// Multiplier from internal "meters" to this unit.
    public var perMeter: Double {
        switch self {
        case .meters: return 1
        case .kilometers: return 1.0 / 1000
        case .miles: return 1.0 / 1609.34
        case .feet: return 3.28084
        }
    }

    public static func parse(_ token: String) -> GeoUnit? {
        switch token.uppercased() {
        case "M":  return .meters
        case "KM": return .kilometers
        case "MI": return .miles
        case "FT": return .feet
        default:   return nil
        }
    }
}

/// 52-bit interleaved geohash, the Redis encoding (26 bits per axis).
public enum GeoHash {
    /// Latitude bounds for the Redis geohash grid: [-85.05112878, 85.05112878].
    public static let latRange: (lo: Double, hi: Double) = (-85.05112878, 85.05112878)
    /// Longitude bounds: [-180, 180].
    public static let lonRange: (lo: Double, hi: Double) = (-180, 180)
    /// Steps (bits per axis) used by Redis.
    public static let steps = 26

    /// Encode (lon, lat) → 52-bit interleaved geohash. Returns nil for
    /// out-of-range inputs.
    public static func encode(lon: Double, lat: Double) -> UInt64? {
        guard lat >= latRange.lo && lat <= latRange.hi,
              lon >= lonRange.lo && lon <= lonRange.hi else { return nil }
        let latBits = quantize(lat, range: latRange)
        let lonBits = quantize(lon, range: lonRange)
        return interleave(low: latBits, high: lonBits)
    }

    /// Decode a 52-bit geohash → (lon, lat) at the cell center.
    public static func decode(_ score: UInt64) -> (lon: Double, lat: Double) {
        let (latBits, lonBits) = deinterleave(score)
        let lat = midpoint(latBits, range: latRange)
        let lon = midpoint(lonBits, range: lonRange)
        return (lon, lat)
    }

    /// 11-character base32 geohash of (lon, lat) using the
    /// `0123456789bcdefghjkmnpqrstuvwxyz` alphabet (Redis GEOHASH
    /// output). Note: this is NOT the same as the 52-bit score; it's
    /// a 55-bit standard geohash truncated to 11 chars.
    public static func base32(lon: Double, lat: Double) -> String? {
        // Standard geohash with full -90..90 lat range, encoded
        // alternating bits then base32-grouped (5 bits per char).
        let standardLatRange = (-90.0, 90.0)
        guard lon >= -180 && lon <= 180,
              lat >= standardLatRange.0 && lat <= standardLatRange.1 else { return nil }
        var bits: [UInt8] = []
        var lo = -180.0, hi = 180.0
        var llo = standardLatRange.0, lhi = standardLatRange.1
        var even = true
        while bits.count < 55 {
            if even {
                let mid = (lo + hi) / 2
                if lon >= mid { bits.append(1); lo = mid } else { bits.append(0); hi = mid }
            } else {
                let mid = (llo + lhi) / 2
                if lat >= mid { bits.append(1); llo = mid } else { bits.append(0); lhi = mid }
            }
            even.toggle()
        }
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        var out = ""
        for chunk in stride(from: 0, to: 55, by: 5) {
            var v: Int = 0
            for i in 0..<5 {
                v = (v << 1) | Int(bits[chunk + i])
            }
            out.append(alphabet[v])
        }
        return out
    }

    /// Distance in meters between two (lon, lat) points using
    /// haversine on the WGS-84 mean Earth radius (6372797.560856 m,
    /// matches Redis).
    public static func haversine(lon1: Double, lat1: Double,
                                 lon2: Double, lat2: Double) -> Double {
        let R = 6_372_797.560856
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad
        let dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * rad) * cos(lat2 * rad) *
                sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(a)))
    }

    // MARK: - private

    /// Quantize a value within a range to `steps`-bit unsigned integer.
    private static func quantize(_ v: Double, range: (lo: Double, hi: Double)) -> UInt32 {
        let frac = (v - range.lo) / (range.hi - range.lo)
        let clamped = min(max(0, frac), 0.999_999_999_999)
        let scaled = clamped * Double(UInt64(1) << UInt64(steps))
        return UInt32(scaled)
    }

    /// Midpoint of the cell identified by `bits` within the given range.
    private static func midpoint(_ bits: UInt32, range: (lo: Double, hi: Double)) -> Double {
        let total = Double(UInt64(1) << UInt64(steps))
        let cellSize = (range.hi - range.lo) / total
        return range.lo + (Double(bits) + 0.5) * cellSize
    }

    /// Interleave 26-bit `low` and 26-bit `high` into a 52-bit result,
    /// matching the Redis order: lon takes the odd-numbered (high)
    /// bits and lat takes the even-numbered (low) bits.
    private static func interleave(low: UInt32, high: UInt32) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<UInt64(steps) {
            let lb = UInt64((low >> i) & 1)
            let hb = UInt64((high >> i) & 1)
            result |= (lb << (2 * i))
            result |= (hb << (2 * i + 1))
        }
        return result
    }

    private static func deinterleave(_ x: UInt64) -> (low: UInt32, high: UInt32) {
        var low: UInt32 = 0
        var high: UInt32 = 0
        for i in 0..<UInt64(steps) {
            if (x >> (2 * i)) & 1 == 1 { low |= UInt32(1) << UInt32(i) }
            if (x >> (2 * i + 1)) & 1 == 1 { high |= UInt32(1) << UInt32(i) }
        }
        return (low, high)
    }
}

extension KeyStore {

    /// Adds geo members. Returns the number of NEW members added (mirrors
    /// ZADD semantics — updates to existing members don't count).
    @discardableResult
    public func geoAdd(key: String, items: [(lon: Double, lat: Double, member: Data)]) throws -> Int {
        var pairs: [(Double, Data)] = []
        pairs.reserveCapacity(items.count)
        for it in items {
            guard let score = GeoHash.encode(lon: it.lon, lat: it.lat) else {
                throw KeyStoreError.appError("ERR value is not a valid longitude,latitude pair")
            }
            // Store the 52-bit hash as a Double — every UInt64 ≤ 2^53
            // round-trips losslessly through Double, and 2^52 fits with
            // room to spare.
            pairs.append((Double(score), it.member))
        }
        return try zadd(key: key, members: pairs)
    }

    /// Returns the `(lon, lat)` pair for each requested member; nil for
    /// members that are missing from the set.
    public func geoPos(key: String, members: [Data]) throws -> [(Double, Double)?] {
        var out: [(Double, Double)?] = []
        out.reserveCapacity(members.count)
        for m in members {
            if let score = try zscore(key: key, member: m) {
                let raw = UInt64(score)
                let (lon, lat) = GeoHash.decode(raw)
                out.append((lon, lat))
            } else {
                out.append(nil)
            }
        }
        return out
    }

    /// Distance in `unit` between two members; nil if either is missing.
    public func geoDist(key: String, a: Data, b: Data, unit: GeoUnit) throws -> Double? {
        guard let sa = try zscore(key: key, member: a),
              let sb = try zscore(key: key, member: b) else { return nil }
        let (lon1, lat1) = GeoHash.decode(UInt64(sa))
        let (lon2, lat2) = GeoHash.decode(UInt64(sb))
        return GeoHash.haversine(lon1: lon1, lat1: lat1, lon2: lon2, lat2: lat2) * unit.perMeter
    }

    /// Returns the base32 11-char geohash for each requested member;
    /// nil for missing members.
    public func geoHash(key: String, members: [Data]) throws -> [String?] {
        var out: [String?] = []
        out.reserveCapacity(members.count)
        for m in members {
            if let score = try zscore(key: key, member: m) {
                let (lon, lat) = GeoHash.decode(UInt64(score))
                out.append(GeoHash.base32(lon: lon, lat: lat))
            } else {
                out.append(nil)
            }
        }
        return out
    }

    /// Shape of a GEOSEARCH region.
    public enum GeoShape: Sendable {
        case radius(meters: Double)
        case box(widthMeters: Double, heightMeters: Double)
    }

    /// A single GEOSEARCH result row, plus pre-decoded extras the
    /// caller can include in the wire reply.
    public struct GeoMatch: Sendable {
        public let member: Data
        public let lon: Double
        public let lat: Double
        public let distanceMeters: Double
        public let score: UInt64
    }

    /// GEOSEARCH driver. Caller passes either an anchor member
    /// (FROMMEMBER) or explicit anchor coordinates (FROMLONLAT), and
    /// either BYRADIUS or BYBOX. Matches are filtered by the shape and
    /// sorted ascending by distance by default.
    public func geoSearch(key: String,
                          anchor: (lon: Double, lat: Double),
                          shape: GeoShape,
                          ascending: Bool = true,
                          count: Int? = nil,
                          countAny: Bool = false) throws -> [GeoMatch] {
        // Brute-force scan over the entire zset: decode every score, do
        // the geometry check. swiftka is small-scale so this is fine;
        // the bounding-box prefilter Redis does is an optimisation, not
        // a correctness requirement.
        let all = try zrangeByScore(key: key,
                                    min: -Double.greatestFiniteMagnitude,
                                    max: Double.greatestFiniteMagnitude)
        var matches: [GeoMatch] = []
        for entry in all {
            let raw = UInt64(entry.score)
            let (lon, lat) = GeoHash.decode(raw)
            let dist = GeoHash.haversine(lon1: anchor.lon, lat1: anchor.lat,
                                         lon2: lon, lat2: lat)
            let included: Bool
            switch shape {
            case .radius(let r):
                included = dist <= r
            case .box(let w, let h):
                // Approximate box test: convert width/height (meters)
                // to lon/lat deltas at the anchor latitude. Latitude
                // delta is constant; longitude delta scales with cos(lat).
                let metersPerDegLat = 111_320.0
                let dLat = abs(lat - anchor.lat) * metersPerDegLat
                let metersPerDegLon = 111_320.0 * cos(anchor.lat * .pi / 180)
                let dLon = abs(lon - anchor.lon) * metersPerDegLon
                included = dLon <= w / 2 && dLat <= h / 2
            }
            if included {
                matches.append(GeoMatch(member: entry.elem, lon: lon, lat: lat,
                                        distanceMeters: dist, score: raw))
            }
        }
        if !countAny || count == nil {
            matches.sort { ascending ? $0.distanceMeters < $1.distanceMeters
                                     : $0.distanceMeters > $1.distanceMeters }
        }
        if let c = count {
            matches = Array(matches.prefix(c))
        }
        return matches
    }
}
