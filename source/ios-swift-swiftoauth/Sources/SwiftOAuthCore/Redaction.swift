import Foundation

/// Helpers that keep secrets out of logs and `description`s. swiftoauth never
/// prints a raw token or `Authorization` header unless the user explicitly
/// asks (e.g. `--show-token`).
public enum Redaction {
    /// The mask substituted for any redacted secret. ASCII so it renders
    /// correctly when printed to a Windows console (legacy code pages).
    public static let placeholder = "<redacted>"

    /// Header names whose values must never be logged (matched case-insensitively).
    public static let sensitiveHeaders: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "proxy-authorization",
    ]

    /// Mask a token. With `keepingPrefix > 0`, the first few characters are
    /// retained as a debugging hint while the secret remainder is masked.
    public static func redactToken(_ token: String, keepingPrefix prefix: Int = 0) -> String {
        guard prefix > 0, token.count > prefix else { return placeholder }
        return String(token.prefix(prefix)) + "…" + placeholder
    }

    /// Return a copy of `headers` with the values of sensitive headers masked.
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var output = headers
        for key in headers.keys where sensitiveHeaders.contains(key.lowercased()) {
            output[key] = placeholder
        }
        return output
    }

    /// Mask the secret values in a JSON token-response body so raw exchange
    /// payloads are safe to log.
    public static func redactTokenJSON(_ body: String) -> String {
        var result = body
        for field in ["access_token", "refresh_token", "id_token", "client_secret"] {
            let pattern = "\"\(field)\"\\s*:\\s*\"[^\"]*\""
            result = result.replacingOccurrences(
                of: pattern,
                with: "\"\(field)\":\"\(placeholder)\"",
                options: .regularExpression
            )
        }
        return result
    }
}
