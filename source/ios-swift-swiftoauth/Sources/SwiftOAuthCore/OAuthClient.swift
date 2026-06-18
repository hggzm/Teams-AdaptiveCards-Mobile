// Source: RFC 6749 §4.1.3 (authorization-code exchange), §6 (refresh),
//         RFC 6750 §2.1 (bearer identity request).
//
// Orchestrates a provider + a transport: build the provider's request, send it,
// check the status, and parse the body back into a value type. No secrets are
// ever logged here; non-2xx bodies are redacted before being surfaced in errors.
import Foundation

/// Drives provider flows over an injected ``OAuthTransport``.
public struct OAuthClient: Sendable {
    public let transport: any OAuthTransport

    public init(transport: any OAuthTransport) {
        self.transport = transport
    }

    /// Exchange an authorization `code` for a ``TokenSet`` (RFC 6749 §4.1.3).
    public func exchangeAuthorizationCode(
        provider: any OAuthProvider,
        code: String,
        codeVerifier: String?,
        redirectURI: URL
    ) async throws -> TokenSet {
        let request = provider.tokenRequest(code: code, codeVerifier: codeVerifier, redirectURI: redirectURI)
        let response = try await transport.send(request)
        try Self.requireSuccessForToken(response)
        return try provider.parseToken(response.body)
    }

    /// Exchange a refresh token for a fresh ``TokenSet`` (RFC 6749 §6).
    public func refresh(
        provider: any OAuthProvider,
        refreshToken: String
    ) async throws -> TokenSet {
        let request = provider.refreshRequest(refreshToken: refreshToken)
        let response = try await transport.send(request)
        try Self.requireSuccessForToken(response)
        return try provider.parseToken(response.body)
    }

    /// Fetch the authenticated identity with a bearer token (RFC 6750 §2.1).
    public func fetchIdentity(
        provider: any OAuthProvider,
        accessToken: String
    ) async throws -> Identity {
        let request = provider.identityRequest(accessToken: accessToken)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw Self.providerError(response)
        }
        return try provider.parseIdentity(response.body)
    }

    /// Revoke a token (RFC 7009, or the provider's own revocation scheme).
    ///
    /// Throws ``OAuthError/revocationUnavailable(_:)`` if the provider does not
    /// support revocation or cannot build a revocation request from its current
    /// configuration, and ``OAuthError/providerError(code:description:)`` if the
    /// provider rejects the request.
    public func revoke(
        provider: any OAuthProvider,
        token: String,
        tokenTypeHint: TokenTypeHint = .accessToken
    ) async throws {
        guard let revocable = provider as? TokenRevocation else {
            throw OAuthError.revocationUnavailable("provider '\(provider.id)' does not support token revocation")
        }
        guard let request = revocable.revokeRequest(token: token, tokenTypeHint: tokenTypeHint) else {
            throw OAuthError.revocationUnavailable("provider '\(provider.id)' needs client credentials to revoke")
        }
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw Self.providerError(response)
        }
    }

    // MARK: - Status handling

    /// Token endpoints: a non-2xx is a hard failure. (Some providers, e.g.
    /// GitHub, return 200 with an `{"error": …}` body instead — that case is
    /// left to `parseToken`, which detects and throws it.)
    private static func requireSuccessForToken(_ response: OAuthHTTPResponse) throws {
        guard response.isSuccess else {
            throw providerError(response)
        }
    }

    /// Build a redacted provider error from a non-2xx response.
    private static func providerError(_ response: OAuthHTTPResponse) -> OAuthError {
        let raw = String(decoding: response.body, as: UTF8.self)
        let safe = Redaction.redactTokenJSON(raw)
        let trimmed = safe.count > 500 ? String(safe.prefix(500)) + "…" : safe
        return .providerError(code: "http_\(response.status)", description: trimmed.isEmpty ? nil : trimmed)
    }
}
