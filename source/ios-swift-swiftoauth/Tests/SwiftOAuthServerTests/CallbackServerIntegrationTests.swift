import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftOAuthServer
import SwiftOAuthCore

/// End-to-end loopback tests: a real Hummingbird server binds an ephemeral
/// 127.0.0.1 port, we drive the browser-redirect step with a plain HTTP GET
/// against that port, and assert the captured outcome. No external OAuth
/// provider is contacted — the "authorize" half is simulated by hitting the
/// callback URL the way a provider's 302 would.
@Suite struct CallbackServerIntegrationTests {

    /// Perform a GET and return (status, body) — cross-platform.
    private func get(_ url: URL) async throws -> (Int, String) {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Probe a URL with a short timeout. Used to assert the server has stopped
    /// answering after shutdown; on Windows a refused loopback connection can
    /// otherwise sit on `URLSession`'s default 60s timeout, so cap it tightly.
    private func probe(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        _ = try await session.data(from: url)
    }

    /// Build the callback URL a provider would redirect to for a bound server.
    private func callbackURL(_ redirectURI: URL, query: String) -> URL {
        URL(string: redirectURI.absoluteString + "?" + query)!
    }

    @Test func happyPathCaptureCodeAndShutdown() async throws {
        let state = OAuthState.generate().value
        let server = CallbackServer(config: .init(expectedState: state))

        let result = try await server.run { redirectURI in
            // Simulate the provider's redirect back to the loopback server.
            let url = self.callbackURL(redirectURI, query: "code=GOODCODE&state=\(state)")
            _ = try? await self.get(url)
        }

        #expect(result.outcome == .code("GOODCODE"))
        #expect(result.boundPort > 0)
        #expect(result.redirectURI.absoluteString.hasPrefix("http://127.0.0.1:"))

        // The server must have shut down — the port should no longer answer.
        let probeURL = self.callbackURL(result.redirectURI, query: "code=x&state=\(state)")
        do {
            try await self.probe(probeURL)
            Issue.record("server still answering after one-shot shutdown")
        } catch {
            // expected: connection refused (or a fast timeout)
        }
    }

    @Test func returnedSuccessPageToBrowser() async throws {
        let state = OAuthState.generate().value
        let server = CallbackServer(config: .init(expectedState: state))

        // Capture the HTTP response the "browser" receives via onBound.
        let captured = ResponseBox()
        let result = try await server.run { redirectURI in
            let url = self.callbackURL(redirectURI, query: "code=OK&state=\(state)")
            if let pair = try? await self.get(url) { await captured.set(pair) }
        }

        #expect(result.outcome == .code("OK"))
        let page = await captured.value
        #expect(page?.0 == 200)
        #expect(page?.1.contains("You may close this tab") == true)
    }

    @Test func stateMismatchIsRejectedEndToEnd() async throws {
        let state = OAuthState.generate().value
        let server = CallbackServer(config: .init(expectedState: state))

        let result = try await server.run { redirectURI in
            // Wrong state — simulates a CSRF / forged callback.
            let url = self.callbackURL(redirectURI, query: "code=GOODCODE&state=TAMPERED")
            _ = try? await self.get(url)
        }

        #expect(result.outcome == .stateMismatch)
    }

    @Test func providerErrorIsSurfacedEndToEnd() async throws {
        let state = OAuthState.generate().value
        let server = CallbackServer(config: .init(expectedState: state))

        let result = try await server.run { redirectURI in
            let url = self.callbackURL(redirectURI, query: "error=access_denied&state=\(state)")
            _ = try? await self.get(url)
        }

        #expect(result.outcome == .providerError(error: "access_denied", description: nil))
    }

    /// Small actor box to ferry the captured browser response out of the
    /// `onBound` closure.
    private actor ResponseBox {
        private(set) var value: (Int, String)?
        func set(_ v: (Int, String)) { value = v }
    }
}
