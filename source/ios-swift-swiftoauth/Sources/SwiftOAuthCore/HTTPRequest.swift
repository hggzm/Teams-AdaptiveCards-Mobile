// Source: RFC 6749 §3.2 / §4.1 / RFC 6750 §2.1 — token-endpoint POST and the
//         bearer-token identity GET, expressed here as a pure value.
import Foundation

/// A provider-built HTTP request, as a pure value with no networking attached.
///
/// Keeping requests as plain data lets the three providers be unit-tested with
/// zero network access (assert on the request shape), and lets the CLI's
/// transport layer (AsyncHTTPClient, added in a later phase) execute them.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case GET
        case POST
        case DELETE
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Build a POST with an `application/x-www-form-urlencoded` body from form
    /// `fields` (the content type OAuth token endpoints expect, RFC 6749 §4.1.3).
    public static func formPOST(
        url: URL,
        fields: [String: String],
        headers: [String: String] = [:]
    ) -> HTTPRequest {
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded"
        let encoded = FormURLEncoding.encode(fields)
        return HTTPRequest(method: .POST, url: url, headers: merged, body: Data(encoded.utf8))
    }

    /// A redaction-safe one-line rendering for logs: sensitive header values
    /// are masked and the body is never included.
    public var redactedDescription: String {
        let renderedHeaders = Redaction.redactHeaders(headers)
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: ", ")
        return "\(method.rawValue) \(url.absoluteString) [\(renderedHeaders)]"
    }
}
