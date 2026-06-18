// main.swift
// Flavor B ("transport / HTTP") symbol-check demo.
//
// Binds the vendored swiftoauth loopback server (SwiftOAuthServer's
// CallbackServer) on 127.0.0.1, then drives one real loopback HTTP
// round-trip that carries a fact derived from the canonical
// "Hello World" Adaptive Card.
//
// Steps:
//   1. Parse the canonical adaptivecards.io card with Foundation
//      JSONDecoder and derive the fact `body[0].type` (== "TextBlock").
//   2. Generate a CSRF `state` (SwiftOAuthCore.OAuthState) and a PKCE
//      pair (SwiftOAuthCore.PKCE); assert the PKCE pair is RFC 7636-valid.
//   3. Bind SwiftOAuthServer.CallbackServer on 127.0.0.1:<ephemeral>.
//   4. From the `onBound` hook, issue a real HTTP GET to the bound
//      loopback URL carrying the derived card fact as the OAuth `code`
//      together with the `state` — exactly the shape a provider's
//      browser redirect takes (RFC 6749 §4.1.2 / RFC 8252 §7.3).
//   5. The server validates `state` exactly (constant-time CSRF check)
//      and captures the code; assert the captured code == the derived
//      card fact == "TextBlock".
//   6. Print `PASS adaptivecards-swiftoauth-http` and exit 0; any
//      deviation prints `FAIL ...` and exits 1.
//
// Symbols exercised (cross-referenced in README.md):
//   - SwiftOAuthCore.OAuthState  (generate, .value, .matches)
//   - SwiftOAuthCore.PKCE        (generate, .codeVerifier, .codeChallenge,
//                                 isValidVerifier, challenge(for:))
//   - SwiftOAuthServer.CallbackServerConfig  (init, redirectURI(boundPort:))
//   - SwiftOAuthServer.CallbackServer        (init(config:), run(onBound:))
//   - SwiftOAuthServer.CallbackServer.RunResult (.outcome, .boundPort, .redirectURI)
//   - SwiftOAuthServer.CallbackOutcome       (.code case)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftOAuthCore
import SwiftOAuthServer

// A `main.swift` file is the executable entry point, so drive the demo
// inline with top-level `await` (no `@main`).
do {
    try await runDemo()
    print("PASS adaptivecards-swiftoauth-http")
    exit(0)
} catch {
    print("FAIL adaptivecards-swiftoauth-http: \(error)")
    exit(1)
}

enum DemoError: Error, CustomStringConvertible {
    case malformedSample
    case unexpectedOutcome(String)
    case factMismatch(expected: String, got: String)

    var description: String {
        switch self {
        case .malformedSample:
            return "canonical sample card did not decode as expected"
        case .unexpectedOutcome(let o):
            return "loopback server returned an unexpected outcome: \(o)"
        case .factMismatch(let expected, let got):
            return "round-tripped fact mismatch: expected \(expected), got \(got)"
        }
    }
}

// Minimal Codable shape for the canonical Adaptive Card. Foundation
// JSONDecoder parses the card; we only need `type` and `body[].type`.
private struct AdaptiveCard: Decodable {
    let type: String
    let body: [Element]
    struct Element: Decodable { let type: String }
}

func runDemo() async throws {
    // 1) Parse the canonical sample card and derive `body[0].type`.
    let cardData = Data(SampleCard.helloWorldJSON.utf8)
    let card = try JSONDecoder().decode(AdaptiveCard.self, from: cardData)
    guard card.type == "AdaptiveCard", let firstElement = card.body.first else {
        throw DemoError.malformedSample
    }
    let cardFact = firstElement.type           // "TextBlock"
    print("derived card fact body[0].type = \(cardFact)")

    // 2) Generate the CSRF state + PKCE pair from the kit's core API.
    let state = OAuthState.generate()
    let pkce = PKCE.generate()
    guard PKCE.isValidVerifier(pkce.codeVerifier),
          PKCE.challenge(for: pkce.codeVerifier) == pkce.codeChallenge else {
        throw DemoError.malformedSample
    }
    print("state (\(state.value.count) chars) + PKCE S256 challenge (\(pkce.codeChallenge.count) chars) generated")

    // 3) Bind the loopback callback server on 127.0.0.1 (ephemeral port).
    let server = CallbackServer(config: .init(expectedState: state.value))

    // 4+5) Drive one real loopback HTTP round-trip from `onBound`: the
    //      derived card fact rides back as the OAuth `code`, guarded by the
    //      `state`. The server validates `state` and captures the code.
    let result = try await server.run { redirectURI in
        let callback = redirectURI.absoluteString
            + "?code=\(cardFact)&state=\(state.value)"
        guard let url = URL(string: callback) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }

    print("server bound 127.0.0.1:\(result.boundPort), redirect_uri = \(result.redirectURI.absoluteString)")
    guard result.redirectURI.absoluteString.hasPrefix("http://127.0.0.1:") else {
        throw DemoError.unexpectedOutcome("redirect_uri not loopback: \(result.redirectURI)")
    }

    // 6) Assert the captured code == the card fact carried over the wire.
    switch result.outcome {
    case .code(let captured):
        guard captured == cardFact else {
            throw DemoError.factMismatch(expected: cardFact, got: captured)
        }
        // Sanity: the CSRF state we generated matches what the server validated.
        guard state.matches(state.value) else {
            throw DemoError.unexpectedOutcome("state self-check failed")
        }
        print("loopback round-trip captured code == card fact (\(captured)) with state validated")
    case .stateMismatch:
        throw DemoError.unexpectedOutcome("stateMismatch (CSRF check rejected the callback)")
    case .providerError(let error, let description):
        throw DemoError.unexpectedOutcome("providerError \(error) \(description ?? "")")
    case .missingParameters:
        throw DemoError.unexpectedOutcome("missingParameters")
    }
}
