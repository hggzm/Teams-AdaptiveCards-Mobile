/// Decides whether a relative path is excluded from a sync by a set of glob
/// patterns. Pure and total — no I/O — so the matching rules can be exhaustively
/// unit-tested.
///
/// Matching rules (deliberately small and predictable):
/// - A pattern is a glob where `*` matches any run of characters (including
///   `/`) and `?` matches exactly one character. Everything else is literal.
/// - A pattern matches an entry when it matches the entry's **full relative
///   path** (e.g. `docs/intro.md`) *or* the entry's **base name** (the last
///   `/`-separated component, e.g. `intro.md`).
/// - When an excluded entry is a directory, the caller prunes its whole subtree.
///
/// Examples: `*.tmp` excludes any path ending in `.tmp`; `build` excludes any
/// file or directory named `build`; `docs/*` excludes the direct children of a
/// top-level `docs` directory.
public enum ExcludeFilter {
    /// True when `relativePath` matches any of `patterns`. Empty `patterns`
    /// excludes nothing.
    public static func isExcluded(relativePath: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let base = String(relativePath.split(separator: "/").last ?? Substring(relativePath))
        for pattern in patterns where !pattern.isEmpty {
            if matches(pattern: pattern, name: relativePath) || matches(pattern: pattern, name: base) {
                return true
            }
        }
        return false
    }

    /// Classic linear wildcard match with backtracking. `*` matches any
    /// sequence (including empty), `?` matches any single character.
    static func matches(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let s = Array(name)
        var pi = 0
        var si = 0
        var starIndex = -1
        var matchIndex = 0

        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi
                matchIndex = si
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                si = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
