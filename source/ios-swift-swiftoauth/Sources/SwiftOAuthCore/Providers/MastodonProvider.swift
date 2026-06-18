// Source: docs.joinmastodon.org — OAuth and Apps.
//   register:  POST {instance}/api/v1/apps            (docs.joinmastodon.org/methods/apps)
//   authorize: {instance}/oauth/authorize             (docs.joinmastodon.org/spec/oauth)
//   token:     POST {instance}/oauth/token
//   identity:  GET {instance}/api/v1/accounts/verify_credentials
//   revoke:    POST {instance}/oauth/revoke            (docs.joinmastodon.org/methods/oauth)
//   PKCE: Mastodon supports the S256 code challenge for the authorization-code grant.
//
// Mastodon is per-instance: there is no single base URL. Every endpoint is
// relative to the instance the user is signing in to, supplied via
// `OAuthClientConfig.instanceBaseURL`. Each instance also issues its own
// client credentials via dynamic app registration, hence `DynamicClientRegistration`.
import Foundation

public struct MastodonProvider: OAuthProvider, DynamicClientRegistration, TokenRevocation {
    public let id = "mastodon"
    public let usesPKCE = true
    public let config: OAuthClientConfig

    /// The instance base URL (e.g. `https://mastodon.social`). Required — the
    /// supported construction path is `Providers.make`, which validates that
    /// `config.instanceBaseURL` is present before reaching here.
    public let baseURL: URL

    public init(config: OAuthClientConfig) {
        precondition(
            config.instanceBaseURL != nil,
            "MastodonProvider requires config.instanceBaseURL (use Providers.make for a validated error)"
        )
        self.config = config
        self.baseURL = config.instanceBaseURL!
    }

    private func endpoint(_ path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = nil
        return components.url!
    }

    // MARK: - Dynamic app registration (docs.joinmastodon.org/methods/apps)

    public func appRegistrationRequest(
        clientName: String,
        redirectURI: URL,
        scopes: [String],
        website: URL?
    ) -> HTTPRequest {
        var fields = [
            "client_name": clientName,
            "redirect_uris": redirectURI.absoluteString,
            // Mastodon uses space-delimited scopes (e.g. "read write follow").
            "scopes": (scopes.isEmpty ? ["read"] : scopes).joined(separator: " "),
        ]
        if let website { fields["website"] = website.absoluteString }
        return HTTPRequest.formPOST(url: endpoint("/api/v1/apps"), fields: fields)
    }

    public func parseAppRegistration(_ body: Data) throws -> ClientCredentials {
        guard let dto = try? JSONDecoder().decode(MastodonAppDTO.self, from: body),
              let clientID = dto.client_id else {
            throw OAuthError.malformedTokenResponse("could not decode POST /api/v1/apps")
        }
        return ClientCredentials(clientID: clientID, clientSecret: dto.client_secret)
    }

    // MARK: - OAuthProvider

    public func authorizeURL(state: String, codeChallenge: String?, redirectURI: URL) -> URL {
        var components = URLComponents(url: endpoint("/oauth/authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        if !config.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        }
        if let codeChallenge {
            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components.queryItems = items
        return components.url!
    }

    public func tokenRequest(code: String, codeVerifier: String?, redirectURI: URL) -> HTTPRequest {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": redirectURI.absoluteString,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        if let codeVerifier { fields["code_verifier"] = codeVerifier }
        if !config.scopes.isEmpty { fields["scope"] = config.scopes.joined(separator: " ") }
        return HTTPRequest.formPOST(url: endpoint("/oauth/token"), fields: fields)
    }

    public func refreshRequest(refreshToken: String) -> HTTPRequest {
        // Mastodon access tokens are long-lived and historically non-expiring;
        // newer instances accept the standard refresh grant when a token does
        // expire. We build the RFC 6749 §6 request either way.
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        return HTTPRequest.formPOST(url: endpoint("/oauth/token"), fields: fields)
    }

    public func identityRequest(accessToken: String) -> HTTPRequest {
        HTTPRequest(
            method: .GET,
            url: endpoint("/api/v1/accounts/verify_credentials"),
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
            ]
        )
    }

    // RFC 7009 revocation: POST {instance}/oauth/revoke with the client
    // credentials and the token. Source: docs.joinmastodon.org/methods/oauth
    // (the "Revoke token" method). Returns nil without a client secret, which
    // Mastodon's revocation requires.
    public func revokeRequest(token: String, tokenTypeHint: TokenTypeHint) -> HTTPRequest? {
        guard let secret = config.clientSecret, !secret.isEmpty else { return nil }
        let fields = [
            "client_id": config.clientID,
            "client_secret": secret,
            "token": token,
        ]
        return HTTPRequest.formPOST(url: endpoint("/oauth/revoke"), fields: fields)
    }

    public func parseToken(_ body: Data) throws -> TokenSet {
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(MastodonErrorDTO.self, from: body),
           let code = failure.error {
            throw OAuthError.providerError(code: code, description: failure.error_description)
        }
        guard let dto = try? decoder.decode(MastodonTokenDTO.self, from: body),
              let accessToken = dto.access_token else {
            throw OAuthError.malformedTokenResponse("missing access_token")
        }
        // Mastodon reports `created_at` (unix seconds) rather than `expires_in`;
        // tokens are long-lived, so we leave `expiresIn` nil.
        return TokenSet(
            accessToken: accessToken,
            tokenType: dto.token_type ?? "Bearer",
            refreshToken: dto.refresh_token,
            scope: dto.scope,
            expiresIn: dto.expires_in,
            providerID: id
        )
    }

    public func parseIdentity(_ body: Data) throws -> Identity {
        guard let dto = try? JSONDecoder().decode(MastodonAccountDTO.self, from: body) else {
            throw OAuthError.malformedIdentityResponse("could not decode verify_credentials")
        }
        return Identity(
            providerID: id,
            id: dto.id,
            username: dto.username ?? dto.acct,
            displayName: dto.display_name
        )
    }
}

// MARK: - Mastodon response DTOs (internal)

private struct MastodonAppDTO: Decodable {
    let client_id: String?
    let client_secret: String?
}

private struct MastodonTokenDTO: Decodable {
    let access_token: String?
    let token_type: String?
    let scope: String?
    let refresh_token: String?
    let expires_in: Int?
}

private struct MastodonErrorDTO: Decodable {
    let error: String?
    let error_description: String?
}

private struct MastodonAccountDTO: Decodable {
    let id: String
    let username: String?
    let acct: String
    let display_name: String?
}
