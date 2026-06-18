import Testing
import Foundation
@testable import SwiftOAuthServer
import SwiftOAuthCore

@Suite struct CallbackClassifyTests {
    private func q(_ pairs: [(String, String)]) -> [(key: Substring, value: Substring)] {
        pairs.map { (key: Substring($0.0), value: Substring($0.1)) }
    }

    @Test func validCodeWithMatchingState() {
        let outcome = CallbackServer.classify(
            query: q([("state", "STATE123"), ("code", "THECODE")]),
            expectedState: "STATE123"
        )
        #expect(outcome == .code("THECODE"))
    }

    @Test func stateMismatchRejectedBeforeCode() {
        // Even with a valid code present, a wrong state must be rejected.
        let outcome = CallbackServer.classify(
            query: q([("state", "WRONG"), ("code", "THECODE")]),
            expectedState: "STATE123"
        )
        #expect(outcome == .stateMismatch)
    }

    @Test func missingStateRejected() {
        let outcome = CallbackServer.classify(
            query: q([("code", "THECODE")]),
            expectedState: "STATE123"
        )
        #expect(outcome == .stateMismatch)
    }

    @Test func providerErrorSurfaced() {
        let outcome = CallbackServer.classify(
            query: q([("state", "S"), ("error", "access_denied"), ("error_description", "User denied")]),
            expectedState: "S"
        )
        #expect(outcome == .providerError(error: "access_denied", description: "User denied"))
    }

    @Test func emptyCodeIsMissingParameters() {
        let outcome = CallbackServer.classify(
            query: q([("state", "S"), ("code", "")]),
            expectedState: "S"
        )
        #expect(outcome == .missingParameters)
    }

    @Test func noCodeNoErrorIsMissingParameters() {
        let outcome = CallbackServer.classify(
            query: q([("state", "S")]),
            expectedState: "S"
        )
        #expect(outcome == .missingParameters)
    }
}

@Suite struct CallbackServerConfigTests {
    @Test func redirectURIBindsLoopbackIP() {
        // RFC 8252: must be the literal 127.0.0.1, not "localhost".
        let config = CallbackServerConfig(expectedState: "x")
        #expect(config.redirectURI(boundPort: 8080).absoluteString == "http://127.0.0.1:8080/callback")
    }

    @Test func customPathHonoured() {
        let config = CallbackServerConfig(path: "/cb", expectedState: "x")
        #expect(config.redirectURI(boundPort: 9000).absoluteString == "http://127.0.0.1:9000/cb")
    }
}
