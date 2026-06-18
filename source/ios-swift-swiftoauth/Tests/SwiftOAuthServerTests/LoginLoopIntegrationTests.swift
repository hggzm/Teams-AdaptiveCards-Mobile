import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftOAuthServer
import SwiftOAuthCore

/// Fake transport returning a recorded provider token body — no network.
private actor FakeTransport: OAuthTransport {
    private let response: OAuthHTTPResponse
    init(status: Int, body: String) {
        self.response = OAuthHTTPResponse(status: status, body: Data(body.utf8))
    }
    func send(_ request: HTTPRequest) async throws -> OAuthHTTPResponse { response }
}

/// Exercises the exact composition the CLI `login` command performs — loopback
/// callback capture → code → token exchange → token store — but with a fake
/// transport instead of a real provider, and a temp token store. The browser
/// step and AsyncHTTPClient are the only pieces not covered here (they shell out
/// / open a socket and are intentionally left to manual/integration use).
@Suite struct LoginLoopIntegrationTests {

    private func get(_ url: URL) async {
        _ = try? await URLSession.shared.data(from: url)
    }

    @Test func fullAuthorizeToStoredTokenLoop() async throws {
        let provider = GitHubProvider(config: .init(clientID: "CID", clientSecret: "SECRET"))
        let state = OAuthState.generate()
        let server = CallbackServer(config: .init(expectedState: state.value))

        // 1. Capture the callback (simulated provider redirect).
        let result = try await server.run { redirectURI in
            let url = URL(string: redirectURI.absoluteString + "?code=GOODCODE&state=\(state.value)")!
            await self.get(url)
        }
        guard case .code(let code) = result.outcome else {
            Issue.record("expected a code outcome, got \(result.outcome)")
            return
        }

        // 2. Exchange the code via the fake transport.
        let oauthClient = OAuthClient(transport: FakeTransport(
            status: 200,
            body: #"{"access_token":"gho_LOOP","token_type":"bearer","scope":"read:user"}"#
        ))
        let token = try await oauthClient.exchangeAuthorizationCode(
            provider: provider, code: code, codeVerifier: nil, redirectURI: result.redirectURI
        )

        // 3. Persist and read back from a temp store.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftoauth-loop-\(UUID().uuidString)", isDirectory: true)
        let store = TokenStore(directory: dir)
        try store.save(token)

        let loaded = try store.load(providerID: "github")
        #expect(loaded?.accessToken == "gho_LOOP")
        #expect(loaded?.providerID == "github")
    }

    @Test func tamperedStateNeverReachesExchange() async throws {
        let state = OAuthState.generate()
        let server = CallbackServer(config: .init(expectedState: state.value))

        let result = try await server.run { redirectURI in
            let url = URL(string: redirectURI.absoluteString + "?code=GOODCODE&state=FORGED")!
            await self.get(url)
        }
        // A CSRF-tampered callback must surface as a mismatch, not a code.
        #expect(result.outcome == .stateMismatch)
    }
}
