import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct GitHubProviderTests {
    private let config = OAuthClientConfig(
        clientID: "CID", clientSecret: "SECRET", scopes: ["read:user", "user:email"]
    )
    private var provider: GitHubProvider { GitHubProvider(config: config) }
    private let redirect = URL(string: "http://127.0.0.1:8080/callback")!

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func identityAndFlags() {
        #expect(provider.id == "github")
        #expect(provider.usesPKCE == false)
    }

    @Test func authorizeURLShape() {
        let url = provider.authorizeURL(state: "STATE", codeChallenge: nil, redirectURI: redirect)
        #expect(url.absoluteString.hasPrefix("https://github.com/login/oauth/authorize?"))
        let q = query(url)
        #expect(q["client_id"] == "CID")
        #expect(q["redirect_uri"] == "http://127.0.0.1:8080/callback")
        #expect(q["state"] == "STATE")
        #expect(q["scope"] == "read:user user:email")  // space-delimited
        #expect(q["code_challenge"] == nil)
    }

    @Test func authorizeURLIncludesPKCEWhenProvided() {
        let url = provider.authorizeURL(state: "S", codeChallenge: "CHALLENGE", redirectURI: redirect)
        let q = query(url)
        #expect(q["code_challenge"] == "CHALLENGE")
        #expect(q["code_challenge_method"] == "S256")
    }

    @Test func tokenRequestShape() {
        let request = provider.tokenRequest(code: "THECODE", codeVerifier: nil, redirectURI: redirect)
        #expect(request.method == .POST)
        #expect(request.url.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(request.headers["Accept"] == "application/json")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("client_id=CID"))
        #expect(body.contains("client_secret=SECRET"))
        #expect(body.contains("code=THECODE"))
        #expect(body.contains("redirect_uri="))
    }

    @Test func refreshRequestShape() {
        let request = provider.refreshRequest(refreshToken: "ghr_x")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=ghr_x"))
        #expect(body.contains("client_id=CID"))
    }

    @Test func identityRequestShape() {
        let request = provider.identityRequest(accessToken: "TOKEN")
        #expect(request.method == .GET)
        #expect(request.url.absoluteString == "https://api.github.com/user")
        #expect(request.headers["Authorization"] == "Bearer TOKEN")
        #expect(request.headers["User-Agent"] == "swiftoauth")
        #expect(request.headers["Accept"] == "application/vnd.github+json")
    }

    // Recorded fixture — GitHub OAuth App token response (no live call).
    @Test func parseTokenFromFixture() throws {
        let body = Data(#"{"access_token":"gho_FIXTURE","token_type":"bearer","scope":"read:user,user:email"}"#.utf8)
        let token = try provider.parseToken(body)
        #expect(token.accessToken == "gho_FIXTURE")
        #expect(token.tokenType == "bearer")
        #expect(token.scope == "read:user,user:email")
        #expect(token.providerID == "github")
        #expect(token.refreshToken == nil)
    }

    // Recorded fixture — GitHub App expiring-token response with refresh.
    @Test func parseTokenWithRefreshAndExpiry() throws {
        let body = Data(#"{"access_token":"gho_x","token_type":"bearer","scope":"repo","expires_in":28800,"refresh_token":"ghr_FIXTURE"}"#.utf8)
        let token = try provider.parseToken(body)
        #expect(token.refreshToken == "ghr_FIXTURE")
        #expect(token.expiresIn == 28800)
    }

    // Recorded fixture — GitHub returns 200 + {"error": …} on a bad code.
    @Test func parseTokenErrorThrowsProviderError() {
        let body = Data(#"{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}"#.utf8)
        #expect(throws: OAuthError.self) { try provider.parseToken(body) }
    }

    @Test func parseTokenGarbageThrows() {
        #expect(throws: OAuthError.self) { try provider.parseToken(Data("not json".utf8)) }
    }

    // Recorded fixture — GET /user response.
    @Test func parseIdentityFromFixture() throws {
        let body = Data(#"{"login":"octocat","id":583231,"name":"The Octocat","type":"User"}"#.utf8)
        let identity = try provider.parseIdentity(body)
        #expect(identity.providerID == "github")
        #expect(identity.id == "583231")
        #expect(identity.username == "octocat")
        #expect(identity.displayName == "The Octocat")
    }

    @Test func parseIdentityMissingFieldsThrows() {
        #expect(throws: OAuthError.self) { try provider.parseIdentity(Data("{}".utf8)) }
    }
}

@Suite struct ProviderRegistryTests {
    @Test func knownIDsContainsGitHub() {
        #expect(Providers.knownIDs.contains("github"))
    }

    @Test func makeGitHubProvider() throws {
        let provider = try Providers.make(id: "github", config: OAuthClientConfig(clientID: "x"))
        #expect(provider.id == "github")
        #expect(provider.usesPKCE == false)
    }

    @Test func makeUnknownThrows() {
        #expect(throws: OAuthError.self) {
            _ = try Providers.make(id: "nope", config: OAuthClientConfig(clientID: "x"))
        }
    }
}
