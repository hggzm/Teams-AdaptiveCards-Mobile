// Source: docs.github.com — "Authorizing OAuth apps" and "Refreshing user
//   access tokens".
//   https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
//   https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens
//   Identity: GET https://api.github.com/user (requires a User-Agent header).
//   Revoke:   DELETE https://api.github.com/applications/{client_id}/token
//             (docs.github.com/en/rest/apps/oauth-applications#delete-an-app-token)
import Foundation

/// GitHub OAuth provider.
///
/// GitHub OAuth Apps authenticate the token exchange with a `client_secret`
/// (a confidential client); GitHub does not implement PKCE for this flow, so
/// `usesPKCE` is `false`. All endpoints below come from GitHub's own developer
/// documentation (cited above) — not from any third-party port.
public struct GitHubProvider: OAuthProvider, TokenRevocation {
    public let id = "github"
    public let usesPKCE = false
    public let config: OAuthClientConfig

    public init(config: OAuthClientConfig) {
        self.config = config
    }

    private let authorizeEndpoint = URL(string: "https://github.com/login/oauth/authorize")!
    private let tokenEndpoint = URL(string: "https://github.com/login/oauth/access_token")!
    private let identityEndpoint = URL(string: "https://api.github.com/user")!

    public func authorizeURL(state: String, codeChallenge: String?, redirectURI: URL) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        if !config.scopes.isEmpty {
            // GitHub uses space-delimited scopes.
            items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        }
        if let codeChallenge {
            // GitHub ignores PKCE, but forwarding a challenge is a harmless no-op.
            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components.queryItems = items
        return components.url!
    }

    public func tokenRequest(code: String, codeVerifier: String?, redirectURI: URL) -> HTTPRequest {
        var fields = [
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        if let codeVerifier { fields["code_verifier"] = codeVerifier }
        // `Accept: application/json` makes GitHub return a JSON token body
        // instead of the default form-encoded one.
        return HTTPRequest.formPOST(
            url: tokenEndpoint,
            fields: fields,
            headers: ["Accept": "application/json"]
        )
    }

    public func refreshRequest(refreshToken: String) -> HTTPRequest {
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        return HTTPRequest.formPOST(
            url: tokenEndpoint,
            fields: fields,
            headers: ["Accept": "application/json"]
        )
    }

    public func identityRequest(accessToken: String) -> HTTPRequest {
        HTTPRequest(
            method: .GET,
            url: identityEndpoint,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/vnd.github+json",
                // The GitHub REST API rejects requests without a User-Agent.
                "User-Agent": "swiftoauth",
            ]
        )
    }

    // GitHub does NOT implement RFC 7009. An OAuth app revokes one of its tokens
    // via DELETE /applications/{client_id}/token with HTTP Basic auth
    // (client_id:client_secret) and a JSON body {"access_token": "..."}.
    // Source: docs.github.com/en/rest/apps/oauth-applications#delete-an-app-token
    // Returns nil without a client secret, which Basic auth requires.
    public func revokeRequest(token: String, tokenTypeHint: TokenTypeHint) -> HTTPRequest? {
        guard let secret = config.clientSecret, !secret.isEmpty else { return nil }
        let url = URL(string: "https://api.github.com/applications/\(config.clientID)/token")!
        let basic = Data("\(config.clientID):\(secret)".utf8).base64EncodedString()
        let body = try? JSONSerialization.data(withJSONObject: ["access_token": token])
        return HTTPRequest(
            method: .DELETE,
            url: url,
            headers: [
                "Authorization": "Basic \(basic)",
                "Accept": "application/vnd.github+json",
                "User-Agent": "swiftoauth",
            ],
            body: body
        )
    }

    public func parseToken(_ body: Data) throws -> TokenSet {
        let decoder = JSONDecoder()
        // GitHub signals failures with a 200 + {"error": …} body, so check first.
        if let failure = try? decoder.decode(GitHubErrorDTO.self, from: body),
           let code = failure.error {
            throw OAuthError.providerError(code: code, description: failure.error_description)
        }
        guard let dto = try? decoder.decode(GitHubTokenDTO.self, from: body),
              let accessToken = dto.access_token else {
            throw OAuthError.malformedTokenResponse("missing access_token")
        }
        return TokenSet(
            accessToken: accessToken,
            tokenType: dto.token_type ?? "bearer",
            refreshToken: dto.refresh_token,
            scope: dto.scope,
            expiresIn: dto.expires_in,
            providerID: id
        )
    }

    public func parseIdentity(_ body: Data) throws -> Identity {
        guard let dto = try? JSONDecoder().decode(GitHubUserDTO.self, from: body) else {
            throw OAuthError.malformedIdentityResponse("could not decode GET /user")
        }
        return Identity(
            providerID: id,
            id: String(dto.id),
            username: dto.login,
            displayName: dto.name
        )
    }
}

// MARK: - GitHub response DTOs (internal)

private struct GitHubTokenDTO: Decodable {
    let access_token: String?
    let token_type: String?
    let scope: String?
    let expires_in: Int?
    let refresh_token: String?
}

private struct GitHubErrorDTO: Decodable {
    let error: String?
    let error_description: String?
}

private struct GitHubUserDTO: Decodable {
    let id: Int
    let login: String
    let name: String?
}
