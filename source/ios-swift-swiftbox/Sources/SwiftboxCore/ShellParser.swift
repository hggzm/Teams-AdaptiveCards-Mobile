import Foundation

/// Tokenizes a shell line, honoring single quotes, double quotes and
/// backslash escapes. Deliberately small — pipelines, redirection and
/// subshells are future work tracked in the roadmap.
public enum ShellParser {
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var escaped = false

        for ch in line {
            if escaped {
                current.append(ch)
                hasToken = true
                escaped = false
                continue
            }
            switch ch {
            case "\\" where !inSingle:
                escaped = true
                hasToken = true
            case "'" where !inDouble:
                inSingle.toggle()
                hasToken = true
            case "\"" where !inSingle:
                inDouble.toggle()
                hasToken = true
            case " ", "\t":
                if inSingle || inDouble {
                    current.append(ch)
                } else if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
