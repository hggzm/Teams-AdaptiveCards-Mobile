// Source: docs.joinmastodon.org/methods/apps — dynamic app (client) registration.
//         (Conceptually OAuth 2.0 Dynamic Client Registration, RFC 7591, but the
//         concrete fields here are Mastodon's own published `POST /api/v1/apps`.)
import Foundation

/// Client credentials obtained from a provider's dynamic app-registration step.
public struct ClientCredentials: Codable, Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// A provider that registers an app at runtime to obtain client credentials
/// (e.g. Mastodon, where each instance issues its own `client_id`/`client_secret`).
///
/// This is still a pure value transformation: build the registration request,
/// parse the response. The transport executes it, exactly like the token flow.
public protocol DynamicClientRegistration: OAuthProvider {
    /// Build the request that registers an app and yields client credentials.
    func appRegistrationRequest(
        clientName: String,
        redirectURI: URL,
        scopes: [String],
        website: URL?
    ) -> HTTPRequest

    /// Parse the registration response into ``ClientCredentials``.
    func parseAppRegistration(_ body: Data) throws -> ClientCredentials
}
