// Source: RFC 6749 Appendix B / RFC 3986 §2.3 — token endpoints consume an
//         `application/x-www-form-urlencoded` body with percent-encoded values.
import Foundation

/// `application/x-www-form-urlencoded` encoding for OAuth token requests.
public enum FormURLEncoding {
    /// Encode `fields` as a form body. Keys are sorted so output is
    /// deterministic (which keeps fixtures and tests stable).
    public static func encode(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    /// Percent-encode per RFC 3986: leave only the unreserved set unescaped.
    private static func escape(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
