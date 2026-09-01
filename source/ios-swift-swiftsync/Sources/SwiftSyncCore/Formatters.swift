import Foundation

/// Formats a byte count using binary (IEC) units: `B`, `KiB`, `MiB`, …
///
/// Replaces the upstream `humansize` dependency. Rounding is done manually so
/// the output is deterministic and locale-independent — important for the
/// golden-output tests and for parity across macOS, Linux, and Windows.
public enum HumanSize {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

    public static func string(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        // Round to one decimal place without String(format:) to dodge any
        // locale-dependent decimal separators.
        let scaled = Int64((value * 10).rounded())
        let whole = scaled / 10
        let frac = abs(scaled % 10)
        return "\(whole).\(frac) \(units[unitIndex])"
    }
}

/// Formats a whole number of seconds as a zero-padded `HH:MM:SS` clock.
///
/// Replaces the upstream `humantime` dependency for the live ETA. Hours are not
/// capped, so very long transfers render like `200:00:02`. Negative inputs are
/// clamped to zero.
public enum HumanDuration {
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let hours = s / 3600
        let minutes = (s / 60) % 60
        let secs = s % 60
        return "\(pad2(hours)):\(pad2(minutes)):\(pad2(secs))"
    }

    private static func pad2(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}

/// Computes the path of `target` relative to `base`, using `/` separators.
///
/// Replaces the upstream `pathdiff` dependency. Path splitting accepts both `/`
/// and `\` so it behaves identically given POSIX or Windows-style inputs; the
/// result always uses `/`. Returns `"."` when the two paths are equal.
public enum RelativePath {
    public static func string(from base: String, to target: String) -> String {
        let baseParts = components(base)
        let targetParts = components(target)

        var i = 0
        while i < baseParts.count, i < targetParts.count, baseParts[i] == targetParts[i] {
            i += 1
        }

        let ups = baseParts.count - i
        var result = Array(repeating: "..", count: ups)
        result.append(contentsOf: targetParts[i...])
        return result.isEmpty ? "." : result.joined(separator: "/")
    }

    public static func string(from base: URL, to target: URL) -> String {
        string(from: base.path, to: target.path)
    }

    private static func components(_ path: String) -> [String] {
        path
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { $0 != "." }
    }
}
