import Foundation

/// The OAuth client credentials and scopes a provider needs to drive a flow.
///
/// For a confidential client (e.g. a GitHub OAuth App) `clientSecret` is set;
/// for a public client that relies on PKCE it may be `nil`.
public struct OAuthClientConfig: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?
    public let scopes: [String]
    /// Provider-specific base URL (used by per-instance providers like Mastodon).
    public let instanceBaseURL: URL?

    public init(
        clientID: String,
        clientSecret: String? = nil,
        scopes: [String] = [],
        instanceBaseURL: URL? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.instanceBaseURL = instanceBaseURL
    }
}

/// The OAuth shape each supported platform documents, expressed as pure value
/// transformations: build URLs/requests, parse response bodies. No networking
/// lives here, so every provider is unit-testable against recorded fixtures
/// with zero live calls.
public protocol OAuthProvider: Sendable {
    /// Stable provider id, e.g. `"github"`.
    var id: String { get }

    /// Whether this provider's flow uses PKCE (RFC 7636).
    var usesPKCE: Bool { get }

    /// The authorization-request URL (RFC 6749 §4.1.1) to open in the browser.
    func authorizeURL(state: String, codeChallenge: String?, redirectURI: URL) -> URL

    /// The token-exchange request (RFC 6749 §4.1.3) for an authorization `code`.
    func tokenRequest(code: String, codeVerifier: String?, redirectURI: URL) -> HTTPRequest

    /// The refresh-token request (RFC 6749 §6).
    func refreshRequest(refreshToken: String) -> HTTPRequest

    /// The identity request (RFC 6750 bearer usage) that proves the token works.
    func identityRequest(accessToken: String) -> HTTPRequest

    /// Parse a token-endpoint response body into a `TokenSet`.
    func parseToken(_ body: Data) throws -> TokenSet

    /// Parse an identity-endpoint response body into an `Identity`.
    func parseIdentity(_ body: Data) throws -> Identity
}

/// Registry of the built-in providers.
public enum Providers {
    /// IDs of the providers swiftoauth currently implements.
    public static let knownIDs = ["github", "discord", "mastodon"]

    /// Construct a built-in provider by id, or throw `.unknownProvider`.
    ///
    /// Mastodon is per-instance, so it additionally requires
    /// `config.instanceBaseURL`; a missing instance throws `.missingConfiguration`
    /// rather than crashing.
    public static func make(id: String, config: OAuthClientConfig) throws -> any OAuthProvider {
        switch id {
        case "github":
            return GitHubProvider(config: config)
        case "discord":
            return DiscordProvider(config: config)
        case "mastodon":
            guard config.instanceBaseURL != nil else {
                throw OAuthError.missingConfiguration(
                    "mastodon requires an instance URL (set SWIFTOAUTH_MASTODON_INSTANCE, e.g. https://mastodon.social)"
                )
            }
            return MastodonProvider(config: config)
        default:
            throw OAuthError.unknownProvider(id)
        }
    }
}
