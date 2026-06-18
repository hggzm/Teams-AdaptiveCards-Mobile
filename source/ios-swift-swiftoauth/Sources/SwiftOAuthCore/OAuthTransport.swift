// Source: RFC 6749 §4.1.3/§6 (token endpoint) + RFC 6750 §2.1 (bearer identity).
//
// A minimal HTTP transport abstraction. Keeping this a protocol (not a concrete
// networking client) lets the token-exchange / refresh / identity flows be
// unit-tested with a fake transport against recorded provider responses — the
// test suite never opens a socket to a real provider. The CLI supplies the
// concrete async-http-client implementation.
import Foundation

/// A provider-agnostic HTTP response: just the parts the OAuth flows need.
public struct OAuthHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Whether the status is in the 2xx success range.
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Executes an ``HTTPRequest`` and returns the response.
///
/// Conformers MUST keep TLS verification on — swiftoauth has no insecure escape
/// hatch. The protocol is intentionally tiny so a test fake is trivial.
public protocol OAuthTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> OAuthHTTPResponse
}
