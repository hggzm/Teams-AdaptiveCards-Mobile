import Testing
import Foundation
@testable import SwiftOAuthCore

/// A transport that returns a canned response and records what it was asked to
/// send — so the OAuth flows can be exercised without any network access.
private actor FakeTransport: OAuthTransport {
    private let response: OAuthHTTPResponse
    private(set) var lastRequest: HTTPRequest?

    init(status: Int, body: String) {
        self.response = OAuthHTTPResponse(status: status, body: Data(body.utf8))
    }

    func send(_ request: HTTPRequest) async throws -> OAuthHTTPResponse {
        lastRequest = request
        return response
    }

    func recordedRequest() -> HTTPRequest? { lastRequest }
}

@Suite struct OAuthClientTests {
    private let config = OAuthClientConfig(clientID: "CID", clientSecret: "SECRET", scopes: ["read:user"])
    private var github: GitHubProvider { GitHubProvider(config: config) }
    private let redirect = URL(string: "http://127.0.0.1:8080/callback")!

    @Test func exchangeAuthorizationCodeParsesToken() async throws {
        let transport = FakeTransport(
            status: 200,
            body: #"{"access_token":"gho_FIX","token_type":"bearer","scope":"read:user"}"#
        )
        let client = OAuthClient(transport: transport)
        let token = try await client.exchangeAuthorizationCode(
            provider: github, code: "THECODE", codeVerifier: nil, redirectURI: redirect
        )
        #expect(token.accessToken == "gho_FIX")
        #expect(token.providerID == "github")

        // The transport saw the provider's token request.
        let sent = await transport.recordedRequest()
        #expect(sent?.method == .POST)
        #expect(sent?.url.absoluteString == "https://github.com/login/oauth/access_token")
    }

    @Test func refreshParsesToken() async throws {
        let transport = FakeTransport(
            status: 200,
            body: #"{"access_token":"gho_NEW","token_type":"bearer","refresh_token":"ghr_NEW"}"#
        )
        let client = OAuthClient(transport: transport)
        let token = try await client.refresh(provider: github, refreshToken: "ghr_OLD")
        #expect(token.accessToken == "gho_NEW")
        #expect(token.refreshToken == "ghr_NEW")
    }

    @Test func fetchIdentityParsesIdentity() async throws {
        let transport = FakeTransport(
            status: 200,
            body: #"{"login":"octocat","id":583231,"name":"The Octocat"}"#
        )
        let client = OAuthClient(transport: transport)
        let identity = try await client.fetchIdentity(provider: github, accessToken: "gho_x")
        #expect(identity.username == "octocat")
        #expect(identity.id == "583231")
    }

    @Test func nonSuccessStatusThrowsProviderError() async throws {
        let transport = FakeTransport(status: 401, body: #"{"message":"Bad credentials"}"#)
        let client = OAuthClient(transport: transport)
        await #expect(throws: OAuthError.self) {
            _ = try await client.fetchIdentity(provider: github, accessToken: "bad")
        }
    }

    @Test func errorBodyIsRedactedInThrownError() async throws {
        // A non-2xx body that happens to contain a token must be redacted.
        let transport = FakeTransport(
            status: 400,
            body: #"{"error":"x","access_token":"LEAKED"}"#
        )
        let client = OAuthClient(transport: transport)
        do {
            _ = try await client.exchangeAuthorizationCode(
                provider: github, code: "c", codeVerifier: nil, redirectURI: redirect
            )
            Issue.record("expected an error")
        } catch let error as OAuthError {
            #expect(!"\(error)".contains("LEAKED"))
        }
    }
}
