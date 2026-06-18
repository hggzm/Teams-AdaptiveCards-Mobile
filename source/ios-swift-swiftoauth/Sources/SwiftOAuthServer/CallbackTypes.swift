// Source: RFC 6749 §4.1.2 (authorization response) / §4.1.2.1 (error response)
//         + RFC 8252 §7.3 (loopback redirect on 127.0.0.1).
import Foundation
import SwiftOAuthCore

/// The outcome of the one callback the loopback server is waiting for.
public enum CallbackOutcome: Sendable, Equatable {
    /// The provider redirected back with a valid, state-matched authorization
    /// code (RFC 6749 §4.1.2).
    case code(String)
    /// The provider redirected back with an OAuth error (RFC 6749 §4.1.2.1).
    case providerError(error: String, description: String?)
    /// The redirect's `state` did not match (possible CSRF) — rejected.
    case stateMismatch
    /// The redirect carried neither a `code` nor an `error`.
    case missingParameters
}

/// Configuration for a single loopback authorization callback.
public struct CallbackServerConfig: Sendable {
    /// Loopback host. Per RFC 8252 §8.3 this binds the literal IP `127.0.0.1`,
    /// NOT the hostname "localhost".
    public let host: String
    /// TCP port. `0` asks the OS for an ephemeral port; the bound port is then
    /// reported back via ``CallbackServer/boundPort``.
    public let port: Int
    /// The exact callback path the server answers; any other path 404s.
    public let path: String
    /// The CSRF `state` value this callback must match exactly.
    public let expectedState: String
    /// HTML served to the browser after the callback is captured.
    public let successHTML: String

    public init(
        host: String = "127.0.0.1",
        port: Int = 0,
        path: String = "/callback",
        expectedState: String,
        successHTML: String = CallbackServerConfig.defaultSuccessHTML
    ) {
        self.host = host
        self.port = port
        self.path = path
        self.expectedState = expectedState
        self.successHTML = successHTML
    }

    /// The exact loopback redirect URI for a given bound port — the value that
    /// must be sent as `redirect_uri` and registered with the provider.
    public func redirectURI(boundPort: Int) -> URL {
        URL(string: "http://\(host):\(boundPort)\(path)")!
    }

    public static let defaultSuccessHTML = """
    <!doctype html><html><head><meta charset="utf-8">\
    <title>swiftoauth</title></head>\
    <body style="font-family:system-ui;margin:3rem">\
    <h1>Authentication complete</h1>\
    <p>You may close this tab and return to the terminal.</p>\
    </body></html>
    """
}
