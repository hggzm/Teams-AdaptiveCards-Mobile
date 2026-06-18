// Source: RFC 7009 — OAuth 2.0 Token Revocation.
//   Discord and Mastodon expose an RFC 7009-style revocation endpoint; GitHub
//   instead revokes via its own DELETE-based REST call (cited in that provider's
//   file). Each provider builds its own request — this protocol is the shared
//   seam, kept a pure value transformation like the token and registration flows.
import Foundation

/// RFC 7009 §2.1 `token_type_hint`: which kind of token is being revoked.
public enum TokenTypeHint: String, Sendable {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
}

/// A provider that can revoke a previously-issued token.
///
/// `revokeRequest` returns `nil` when revocation cannot be built from the
/// current configuration (e.g. a provider whose revocation endpoint requires a
/// client secret that isn't set). Callers treat `nil` as "revocation not
/// available", never as an error to surface to the user mid-logout.
public protocol TokenRevocation: OAuthProvider {
    func revokeRequest(token: String, tokenTypeHint: TokenTypeHint) -> HTTPRequest?
}
