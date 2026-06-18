import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct TokenSetTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func codableRoundTrip() throws {
        let token = TokenSet(
            accessToken: "at", tokenType: "bearer", refreshToken: "rt",
            scope: "read", expiresIn: 3600, obtainedAt: base, providerID: "github"
        )
        let data = try JSONEncoder().encode(token)
        #expect(try JSONDecoder().decode(TokenSet.self, from: data) == token)
    }

    @Test func expiresAtIsObtainedPlusExpiresIn() {
        let token = TokenSet(accessToken: "x", tokenType: "bearer",
                             expiresIn: 3600, obtainedAt: base, providerID: "github")
        #expect(token.expiresAt == base.addingTimeInterval(3600))
    }

    @Test func isExpiredAcrossLifetime() {
        let token = TokenSet(accessToken: "x", tokenType: "bearer",
                             expiresIn: 3600, obtainedAt: base, providerID: "github")
        #expect(!token.isExpired(now: base))                              // fresh
        #expect(token.isExpired(now: base.addingTimeInterval(3600)))      // at expiry
        #expect(token.isExpired(now: base.addingTimeInterval(4000)))      // past expiry
    }

    @Test func nonExpiringWhenNoExpiresIn() {
        let token = TokenSet(accessToken: "x", tokenType: "bearer", providerID: "github")
        #expect(token.expiresAt == nil)
        #expect(!token.isExpired(now: Date(timeIntervalSince1970: 9_999_999_999)))
    }

    @Test func bearerAuthorizationHeader() {
        let token = TokenSet(accessToken: "SECRET", tokenType: "bearer", providerID: "github")
        #expect(token.authorizationHeader == "Bearer SECRET")
    }

    @Test func descriptionRedactsSecrets() {
        let token = TokenSet(accessToken: "SUPERSECRETACCESS", tokenType: "bearer",
                             refreshToken: "SUPERSECRETREFRESH", providerID: "github")
        let description = token.description
        #expect(!description.contains("SUPERSECRETACCESS"))
        #expect(!description.contains("SUPERSECRETREFRESH"))
        #expect(description.contains("github"))
    }
}

@Suite struct IdentityTests {
    @Test func codableRoundTrip() throws {
        let identity = Identity(providerID: "github", id: "42", username: "octocat",
                                displayName: "The Octocat", raw: ["type": "User"])
        let data = try JSONEncoder().encode(identity)
        #expect(try JSONDecoder().decode(Identity.self, from: data) == identity)
    }
}
