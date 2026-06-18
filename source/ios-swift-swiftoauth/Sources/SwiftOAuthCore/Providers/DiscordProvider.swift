// Source: discord.com/developers/docs/topics/oauth2 — "OAuth2".
//   authorize: https://discord.com/oauth2/authorize
//   token:     https://discord.com/api/oauth2/token  (application/x-www-form-urlencoded)
//   identity:  GET https://discord.com/api/users/@me
//   revoke:    POST https://discord.com/api/oauth2/token/revoke   (RFC 7009)
//   PKCE: Discord supports the S256 code challenge for the authorization-code grant.
import Foundation

/// Discord OAuth provider.
///
/// Discord implements the standard authorization-code grant and supports PKCE
/// (S256), so `usesPKCE` is `true`. A confidential app also sends its
/// `client_secret` in the token request; both are forwarded when present. All
/// endpoints come from Discord's own developer documentation (cited above).
public struct DiscordProvider: OAuthProvider, TokenRevocation {
    public let id = "discord"
    public let usesPKCE = true
    public let config: OAuthClientConfig

    public init(config: OAuthClientConfig) {
        self.config = config
    }

    private let authorizeEndpoint = URL(string: "https://discord.com/oauth2/authorize")!
    private let tokenEndpoint = URL(string: "https://discord.com/api/oauth2/token")!
    private let identityEndpoint = URL(string: "https://discord.com/api/users/@me")!
    private let revokeEndpoint = URL(string: "https://discord.com/api/oauth2/token/revoke")!

    public func authorizeURL(state: String, codeChallenge: String?, redirectURI: URL) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        if !config.scopes.isEmpty {
            // Discord uses space-delimited scopes (e.g. "identify email").
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
            "redirect_uri": redirectURI.absoluteString,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        if let codeVerifier { fields["code_verifier"] = codeVerifier }
        return HTTPRequest.formPOST(url: tokenEndpoint, fields: fields)
    }

    public func refreshRequest(refreshToken: String) -> HTTPRequest {
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        return HTTPRequest.formPOST(url: tokenEndpoint, fields: fields)
    }

    public func identityRequest(accessToken: String) -> HTTPRequest {
        HTTPRequest(
            method: .GET,
            url: identityEndpoint,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
            ]
        )
    }

    // RFC 7009 revocation: form POST with the token, a type hint, and client
    // authentication (Discord requires the client_id, and client_secret for a
    // confidential app).
    public func revokeRequest(token: String, tokenTypeHint: TokenTypeHint) -> HTTPRequest? {
        var fields = [
            "token": token,
            "token_type_hint": tokenTypeHint.rawValue,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        return HTTPRequest.formPOST(url: revokeEndpoint, fields: fields)
    }

    public func parseToken(_ body: Data) throws -> TokenSet {
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(DiscordErrorDTO.self, from: body),
           let code = failure.error {
            throw OAuthError.providerError(code: code, description: failure.error_description)
        }
        guard let dto = try? decoder.decode(DiscordTokenDTO.self, from: body),
              let accessToken = dto.access_token else {
            throw OAuthError.malformedTokenResponse("missing access_token")
        }
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
        guard let dto = try? JSONDecoder().decode(DiscordUserDTO.self, from: body) else {
            throw OAuthError.malformedIdentityResponse("could not decode GET /users/@me")
        }
        return Identity(
            providerID: id,
            id: dto.id,
            username: dto.username,
            displayName: dto.global_name ?? dto.username
        )
    }
}

// MARK: - Discord response DTOs (internal)

private struct DiscordTokenDTO: Decodable {
    let access_token: String?
    let token_type: String?
    let expires_in: Int?
    let refresh_token: String?
    let scope: String?
}

private struct DiscordErrorDTO: Decodable {
    let error: String?
    let error_description: String?
}

private struct DiscordUserDTO: Decodable {
    let id: String
    let username: String
    let global_name: String?
}
