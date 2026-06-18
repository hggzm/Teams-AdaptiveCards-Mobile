import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct PKCETests {
    /// RFC 7636 Appendix B: the canonical S256 verifier → challenge vector.
    @Test func rfc7636AppendixBVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func initComputesAppendixBChallenge() {
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func generatedVerifierIsValidAndS256() {
        let pkce = PKCE.generate()
        #expect(PKCE.isValidVerifier(pkce.codeVerifier))
        #expect(pkce.method == "S256")
    }

    @Test func defaultVerifierIs43Chars() {
        #expect(PKCE.generate().codeVerifier.count == 43)
    }

    @Test func maxEntropyVerifierIs128Chars() {
        #expect(PKCE.generate(verifierByteCount: 96).codeVerifier.count == 128)
    }

    @Test func challengeIsUnpaddedUrlSafe43() {
        let challenge = PKCE.generate().codeChallenge
        #expect(challenge.count == 43)  // SHA-256 → 32 bytes → 43 base64url chars
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test func verifiersAreUnique() {
        #expect(PKCE.generate().codeVerifier != PKCE.generate().codeVerifier)
    }

    @Test func isValidVerifierRejectsBadInput() {
        #expect(PKCE.isValidVerifier("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        #expect(!PKCE.isValidVerifier("tooshort"))
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 42)))   // < 43
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 129)))  // > 128
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 42) + " "))  // space not unreserved
    }
}
