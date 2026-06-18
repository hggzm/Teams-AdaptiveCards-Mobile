import Testing
import Foundation
@testable import SwiftOAuthCore

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

@Suite struct DiscordProviderTests {
    private let config = OAuthClientConfig(clientID: "CID", clientSecret: "SECRET", scopes: ["identify", "email"])
    private var provider: DiscordProvider { DiscordProvider(config: config) }
    private let redirect = URL(string: "http://127.0.0.1:8080/callback")!

    @Test func identityAndFlags() {
        #expect(provider.id == "discord")
        #expect(provider.usesPKCE == true)
    }

    @Test func authorizeURLShape() {
        let url = provider.authorizeURL(state: "STATE", codeChallenge: "CHAL", redirectURI: redirect)
        #expect(url.absoluteString.hasPrefix("https://discord.com/oauth2/authorize?"))
        let q = query(url)
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == "CID")
        #expect(q["redirect_uri"] == "http://127.0.0.1:8080/callback")
        #expect(q["state"] == "STATE")
        #expect(q["scope"] == "identify email")   // space-delimited
        #expect(q["code_challenge"] == "CHAL")
        #expect(q["code_challenge_method"] == "S256")
    }

    @Test func tokenRequestShape() {
        let request = provider.tokenRequest(code: "THECODE", codeVerifier: "VERIFIER", redirectURI: redirect)
        #expect(request.method == .POST)
        #expect(request.url.absoluteString == "https://discord.com/api/oauth2/token")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=THECODE"))
        #expect(body.contains("client_id=CID"))
        #expect(body.contains("client_secret=SECRET"))
        #expect(body.contains("code_verifier=VERIFIER"))
    }

    @Test func refreshRequestShape() {
        let body = String(decoding: provider.refreshRequest(refreshToken: "rt").body ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=rt"))
        #expect(body.contains("client_id=CID"))
    }

    @Test func identityRequestShape() {
        let request = provider.identityRequest(accessToken: "TOKEN")
        #expect(request.method == .GET)
        #expect(request.url.absoluteString == "https://discord.com/api/users/@me")
        #expect(request.headers["Authorization"] == "Bearer TOKEN")
    }

    // Recorded fixture — Discord token response.
    @Test func parseTokenFromFixture() throws {
        let body = Data(#"{"access_token":"dc_FIX","token_type":"Bearer","expires_in":604800,"refresh_token":"dc_R","scope":"identify email"}"#.utf8)
        let token = try provider.parseToken(body)
        #expect(token.accessToken == "dc_FIX")
        #expect(token.tokenType == "Bearer")
        #expect(token.refreshToken == "dc_R")
        #expect(token.expiresIn == 604800)
        #expect(token.providerID == "discord")
    }

    @Test func parseTokenErrorThrows() {
        let body = Data(#"{"error":"invalid_grant","error_description":"Invalid code"}"#.utf8)
        #expect(throws: OAuthError.self) { try provider.parseToken(body) }
    }

    // Recorded fixture — Discord GET /users/@me.
    @Test func parseIdentityFromFixture() throws {
        let body = Data(#"{"id":"80351110224678912","username":"nelly","global_name":"Nelly","discriminator":"0"}"#.utf8)
        let identity = try provider.parseIdentity(body)
        #expect(identity.id == "80351110224678912")
        #expect(identity.username == "nelly")
        #expect(identity.displayName == "Nelly")
    }

    @Test func parseIdentityFallsBackToUsername() throws {
        let body = Data(#"{"id":"1","username":"plain"}"#.utf8)
        #expect(try provider.parseIdentity(body).displayName == "plain")
    }
}

@Suite struct MastodonProviderTests {
    private let instance = URL(string: "https://mastodon.example")!
    private var config: OAuthClientConfig {
        OAuthClientConfig(clientID: "CID", clientSecret: "SECRET", scopes: ["read", "write"], instanceBaseURL: instance)
    }
    private var provider: MastodonProvider { MastodonProvider(config: config) }
    private let redirect = URL(string: "http://127.0.0.1:8080/callback")!

    @Test func identityAndFlags() {
        #expect(provider.id == "mastodon")
        #expect(provider.usesPKCE == true)
        #expect(provider.baseURL == instance)
    }

    @Test func endpointsAreInstanceRelative() {
        let auth = provider.authorizeURL(state: "S", codeChallenge: nil, redirectURI: redirect)
        #expect(auth.absoluteString.hasPrefix("https://mastodon.example/oauth/authorize?"))
        #expect(provider.tokenRequest(code: "c", codeVerifier: nil, redirectURI: redirect)
            .url.absoluteString == "https://mastodon.example/oauth/token")
        #expect(provider.identityRequest(accessToken: "t")
            .url.absoluteString == "https://mastodon.example/api/v1/accounts/verify_credentials")
    }

    @Test func authorizeURLShape() {
        let url = provider.authorizeURL(state: "STATE", codeChallenge: "CHAL", redirectURI: redirect)
        let q = query(url)
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == "CID")
        #expect(q["scope"] == "read write")
        #expect(q["code_challenge"] == "CHAL")
        #expect(q["code_challenge_method"] == "S256")
    }

    @Test func appRegistrationRequestShape() {
        let request = provider.appRegistrationRequest(
            clientName: "swiftoauth", redirectURI: redirect, scopes: ["read", "write"],
            website: URL(string: "https://example.org")
        )
        #expect(request.method == .POST)
        #expect(request.url.absoluteString == "https://mastodon.example/api/v1/apps")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("client_name=swiftoauth"))
        #expect(body.contains("scopes=read%20write"))
        #expect(body.contains("redirect_uris="))
        #expect(body.contains("website="))
    }

    // Recorded fixture — Mastodon POST /api/v1/apps.
    @Test func parseAppRegistrationFromFixture() throws {
        let body = Data(#"{"id":"123","name":"swiftoauth","client_id":"mc_ID","client_secret":"mc_SECRET","vapid_key":"x"}"#.utf8)
        let creds = try provider.parseAppRegistration(body)
        #expect(creds.clientID == "mc_ID")
        #expect(creds.clientSecret == "mc_SECRET")
    }

    @Test func tokenRequestIncludesScope() {
        let body = String(decoding: provider.tokenRequest(code: "c", codeVerifier: "v", redirectURI: redirect).body ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=v"))
        #expect(body.contains("scope=read%20write"))
    }

    // Recorded fixture — Mastodon token (no expires_in; long-lived).
    @Test func parseTokenFromFixture() throws {
        let body = Data(#"{"access_token":"ms_FIX","token_type":"Bearer","scope":"read write","created_at":1573979017}"#.utf8)
        let token = try provider.parseToken(body)
        #expect(token.accessToken == "ms_FIX")
        #expect(token.tokenType == "Bearer")
        #expect(token.scope == "read write")
        #expect(token.expiresIn == nil)
        #expect(token.expiresAt == nil)
        #expect(token.providerID == "mastodon")
    }

    // Recorded fixture — Mastodon GET /verify_credentials.
    @Test func parseIdentityFromFixture() throws {
        let body = Data(#"{"id":"14715","username":"trwnh","acct":"trwnh","display_name":"infinite love"}"#.utf8)
        let identity = try provider.parseIdentity(body)
        #expect(identity.id == "14715")
        #expect(identity.username == "trwnh")
        #expect(identity.displayName == "infinite love")
    }
}

@Suite struct ProviderRegistryDiscordMastodonTests {
    @Test func knownIDsContainsAllThree() {
        #expect(Providers.knownIDs == ["github", "discord", "mastodon"])
    }

    @Test func makeDiscord() throws {
        let provider = try Providers.make(id: "discord", config: OAuthClientConfig(clientID: "x"))
        #expect(provider.id == "discord")
    }

    @Test func makeMastodonRequiresInstance() {
        // Without an instance URL, construction throws a clean config error.
        #expect(throws: OAuthError.self) {
            _ = try Providers.make(id: "mastodon", config: OAuthClientConfig(clientID: "x"))
        }
    }

    @Test func makeMastodonWithInstance() throws {
        let config = OAuthClientConfig(clientID: "x", instanceBaseURL: URL(string: "https://mastodon.social"))
        let provider = try Providers.make(id: "mastodon", config: config)
        #expect(provider.id == "mastodon")
    }
}
