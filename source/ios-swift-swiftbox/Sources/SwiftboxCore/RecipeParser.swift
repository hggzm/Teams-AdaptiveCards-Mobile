import Foundation

/// Parses Termux-style `build.sh` manifests into ``BuildRecipe`` values.
///
/// Termux already maintains a manifest for every package it ships (the
/// `TERMUX_PKG_*` variables plus optional `termux_step_*` shell functions).
/// Reusing that format means swiftbox's catalog can be seeded from, and kept in
/// sync with, the upstream Termux package set — the iOS port becomes a matter of
/// working through a known list rather than rediscovering it.
///
/// Only metadata is interpreted; shell function bodies are detected (so we know
/// a package has custom build logic) but not executed.
public enum RecipeParser {
    public enum ParseError: Error, Equatable {
        case missingName
        case missingVersion(package: String)
    }

    /// Parse `text` into a recipe. `name` is normally the package directory
    /// name (Termux does not store the name inside `build.sh`).
    public static func parse(_ text: String, name: String, origin: String = "termux") throws -> BuildRecipe {
        guard !name.isEmpty else { throw ParseError.missingName }

        var fields: [String: String] = [:]
        var hasCustomSteps = false

        var braceDepth = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // Skip the body of any shell function (e.g. termux_step_make()).
            if braceDepth > 0 {
                braceDepth += line.countOf("{") - line.countOf("}")
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Function definition start: `name() {` possibly opening a body.
            if isFunctionDefinition(trimmed) {
                hasCustomSteps = true
                braceDepth += line.countOf("{") - line.countOf("}")
                continue
            }

            guard let eq = trimmed.firstIndex(of: "="),
                  trimmed[trimmed.startIndex..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { continue }

            let key = String(trimmed[trimmed.startIndex..<eq])
            let rawValue = String(trimmed[trimmed.index(after: eq)...])
            let value = expand(unquote(rawValue), with: fields)
            fields[key] = value
        }

        guard let version = fields["TERMUX_PKG_VERSION"] else {
            throw ParseError.missingVersion(package: name)
        }

        let deps = parseDependencies(fields["TERMUX_PKG_DEPENDS"])
        let platformIndependent = boolField(fields["TERMUX_PKG_PLATFORM_INDEPENDENT"])

        let metadata = RecipeMetadata(
            name: name,
            version: tolerantVersion(version),
            rawVersion: version,
            revision: Int(fields["TERMUX_PKG_REVISION"] ?? "0") ?? 0,
            homepage: fields["TERMUX_PKG_HOMEPAGE"],
            summary: fields["TERMUX_PKG_DESCRIPTION"] ?? "",
            license: fields["TERMUX_PKG_LICENSE"],
            maintainer: fields["TERMUX_PKG_MAINTAINER"],
            dependencies: deps,
            sourceURL: fields["TERMUX_PKG_SRCURL"],
            sha256: fields["TERMUX_PKG_SHA256"],
            platformIndependent: platformIndependent,
            buildInSrc: boolField(fields["TERMUX_PKG_BUILD_IN_SRC"]),
            hasCustomBuildSteps: hasCustomSteps
        )

        return BuildRecipe(
            metadata: metadata,
            kind: inferKind(platformIndependent: platformIndependent, dependencies: deps),
            origin: origin
        )
    }

    // MARK: Helpers

    static func inferKind(platformIndependent: Bool, dependencies: [String]) -> PackageKind {
        if dependencies.contains("perl") { return .perl }
        if dependencies.contains("python") { return .python }
        return platformIndependent ? .interpreted : .nativeBinary
    }

    static func isFunctionDefinition(_ trimmed: String) -> Bool {
        // Matches `something()` or `something() {`.
        guard let paren = trimmed.firstIndex(of: "(") else { return false }
        let nameRange = trimmed[trimmed.startIndex..<paren]
        guard !nameRange.isEmpty,
              nameRange.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let after = trimmed[trimmed.index(after: paren)...]
        return after.hasPrefix(")")
    }

    static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        // Drop a trailing inline comment that is clearly outside quotes.
        if !v.hasPrefix("\"") && !v.hasPrefix("'"), let hash = v.firstIndex(of: "#") {
            v = String(v[v.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if v.count >= 2,
           (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v.removeFirst()
            v.removeLast()
        }
        return v
    }

    /// Expand `${VAR}` / `$VAR` using already-parsed fields (Termux references
    /// like `${TERMUX_PKG_VERSION}` inside SRCURL).
    static func expand(_ value: String, with fields: [String: String]) -> String {
        guard value.contains("$") else { return value }
        let chars = Array(value)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "$" else { out.append(chars[i]); i += 1; continue }
            if i + 1 < chars.count && chars[i + 1] == "{" {
                var j = i + 2, name = ""
                while j < chars.count && chars[j] != "}" { name.append(chars[j]); j += 1 }
                out += fields[name] ?? ""
                i = (j < chars.count) ? j + 1 : j
            } else {
                var j = i + 1, name = ""
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                    name.append(chars[j]); j += 1
                }
                if name.isEmpty { out.append("$"); i += 1 } else { out += fields[name] ?? ""; i = j }
            }
        }
        return out
    }

    static func parseDependencies(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var result: [String] = []
        for piece in raw.split(separator: ",") {
            // Strip version constraints `(>= 1.0)` and alternatives `a | b`.
            var token = piece.trimmingCharacters(in: .whitespaces)
            if let paren = token.firstIndex(of: "(") {
                token = String(token[token.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
            }
            if let bar = token.firstIndex(of: "|") {
                token = String(token[token.startIndex..<bar]).trimmingCharacters(in: .whitespaces)
            }
            if !token.isEmpty { result.append(token) }
        }
        return result
    }

    static func boolField(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.lowercased() == "true" || raw == "1"
    }

    /// Best-effort version parse: strip an epoch (`1:2.3`), keep the first three
    /// numeric dot-components, default missing ones to 0.
    static func tolerantVersion(_ raw: String) -> SemanticVersion {
        var s = raw
        if let colon = s.firstIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        let comps = s.split(separator: ".")
        func num(_ i: Int) -> Int {
            guard i < comps.count else { return 0 }
            let digits = comps[i].prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return SemanticVersion(num(0), num(1), num(2))
    }
}

private extension String {
    func countOf(_ ch: Character) -> Int { reduce(0) { $1 == ch ? $0 + 1 : $0 } }
}
