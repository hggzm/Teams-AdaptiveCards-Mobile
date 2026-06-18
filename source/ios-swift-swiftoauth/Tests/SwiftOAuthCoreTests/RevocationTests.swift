import Testing
import Foundation
@testable import SwiftOAuthCore

// A transport that records the request it was handed and returns a fixed status.
private actor RevokeFakeTransport: OAuthTransport {
    let status: Int
    private(set) var sent: HTTPRequest?
    init(status: Int) { self.status = status }
    func send(_ request: HTTPRequest) async throws -> OAuthHTTPResponse {
        sent = request
        return OAuthHTTPResponse(status: status)
    }
    func recorded() -> HTTPRequest? { sent }
}

// A provider that does NOT support revocation, to exercise the unavailable path.
private struct NonRevocableProvider: OAuthProvider {
    let id = "stub"
    let usesPKCE = false
    private let url = URL(string: "https://example.com")!
    func authorizeURL(state: String, codeChallenge: String?, redirectURI: URL) -> URL { url }
    func tokenRequest(code: String, codeVerifier: String?, redirectURI: URL) -> HTTPRequest { HTTPRequest(method: .POST, url: url) }
    func refreshRequest(refreshToken: String) -> HTTPRequest { HTTPRequest(method: .POST, url: url) }
    func identityRequest(accessToken: String) -> HTTPRequest { HTTPRequest(method: .GET, url: url) }
    func parseToken(_ body: Data) throws -> TokenSet { throw OAuthError.malformedTokenResponse("stub") }
    func parseIdentity(_ body: Data) throws -> Identity { throw OAuthError.malformedIdentityResponse("stub") }
}

@Suite struct TokenTypeHintTests {
    @Test func rawValuesMatchRFC7009() {
        #expect(TokenTypeHint.accessToken.rawValue == "access_token")
        #expect(TokenTypeHint.refreshToken.rawValue == "refresh_token")
    }
}

@Suite struct RevokeRequestTests {
    private let redirect = URL(string: "http://127.0.0.1:8080/callback")!

    // MARK: Discord (RFC 7009)

    @Test func discordRevokeShape() throws {
        let provider = DiscordProvider(config: .init(clientID: "CID", clientSecret: "SECRET"))
        let request = try #require(provider.revokeRequest(token: "TOK", tokenTypeHint: .accessToken))
        #expect(request.method == .POST)
        #expect(request.url.absoluteString == "https://discord.com/api/oauth2/token/revoke")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("token=TOK"))
        #expect(body.contains("token_type_hint=access_token"))
        #expect(body.contains("client_id=CID"))
        #expect(body.contains("client_secret=SECRET"))
    }

    // MARK: Mastodon (RFC 7009, per-instance)

    @Test func mastodonRevokeShape() throws {
        let provider = MastodonProvider(config: .init(
            clientID: "CID", clientSecret: "SECRET",
            instanceBaseURL: URL(string: "https://mastodon.example")
        ))
        let request = try #require(provider.revokeRequest(token: "TOK", tokenTypeHint: .accessToken))
        #expect(request.method == .POST)
        #expect(request.url.absoluteString == "https://mastodon.example/oauth/revoke")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("client_id=CID"))
        #expect(body.contains("client_secret=SECRET"))
        #expect(body.contains("token=TOK"))
    }

    @Test func mastodonRevokeNilWithoutSecret() {
        let provider = MastodonProvider(config: .init(
            clientID: "CID", instanceBaseURL: URL(string: "https://mastodon.example")
        ))
        #expect(provider.revokeRequest(token: "TOK", tokenTypeHint: .accessToken) == nil)
    }

    // MARK: GitHub (its own DELETE-based scheme)

    @Test func githubRevokeShape() throws {
        let provider = GitHubProvider(config: .init(clientID: "CID", clientSecret: "SECRET"))
        let request = try #require(provider.revokeRequest(token: "gho_TOK", tokenTypeHint: .accessToken))
        #expect(request.method == .DELETE)
        #expect(request.url.absoluteString == "https://api.github.com/applications/CID/token")
        // Basic auth decodes to "client_id:client_secret".
        let auth = try #require(request.headers["Authorization"])
        #expect(auth.hasPrefix("Basic "))
        let b64 = String(auth.dropFirst("Basic ".count))
        let decoded = String(decoding: try #require(Data(base64Encoded: b64)), as: UTF8.self)
        #expect(decoded == "CID:SECRET")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("access_token"))
        #expect(body.contains("gho_TOK"))
    }

    @Test func githubRevokeNilWithoutSecret() {
        let provider = GitHubProvider(config: .init(clientID: "CID"))
        #expect(provider.revokeRequest(token: "TOK", tokenTypeHint: .accessToken) == nil)
    }
}

@Suite struct OAuthClientRevokeTests {
    private let github = GitHubProvider(config: .init(clientID: "CID", clientSecret: "SECRET"))

    @Test func revokeSucceedsOn200() async throws {
        let transport = RevokeFakeTransport(status: 200)
        let discord = DiscordProvider(config: .init(clientID: "CID", clientSecret: "SECRET"))
        try await OAuthClient(transport: transport).revoke(provider: discord, token: "TOK")
        let sent = await transport.recorded()
        #expect(sent?.url.absoluteString == "https://discord.com/api/oauth2/token/revoke")
    }

    @Test func revokeSucceedsOn204() async throws {
        // GitHub revocation returns 204 No Content.
        let transport = RevokeFakeTransport(status: 204)
        try await OAuthClient(transport: transport).revoke(provider: github, token: "gho_TOK")
        let sent = await transport.recorded()
        #expect(sent?.method == .DELETE)
    }

    @Test func revokeThrowsOnNonSuccess() async {
        let transport = RevokeFakeTransport(status: 401)
        await #expect(throws: OAuthError.self) {
            try await OAuthClient(transport: transport).revoke(provider: self.github, token: "TOK")
        }
    }

    @Test func revokeUnavailableWhenProviderCannotBuildRequest() async {
        // GitHub without a client secret cannot build a revoke request.
        let noSecret = GitHubProvider(config: .init(clientID: "CID"))
        let transport = RevokeFakeTransport(status: 200)
        await #expect(throws: OAuthError.self) {
            try await OAuthClient(transport: transport).revoke(provider: noSecret, token: "TOK")
        }
    }

    @Test func revokeUnavailableForNonRevocableProvider() async {
        let transport = RevokeFakeTransport(status: 200)
        await #expect(throws: OAuthError.self) {
            try await OAuthClient(transport: transport).revoke(provider: NonRevocableProvider(), token: "TOK")
        }
    }
}
