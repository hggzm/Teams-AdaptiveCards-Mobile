import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct OAuthStateTests {
    @Test func generatedStateDefaultLengthIs43() {
        #expect(OAuthState.generate().value.count == 43)  // 32 bytes → 43 base64url chars
    }

    @Test func generatedStateIsUrlSafe() {
        let value = OAuthState.generate().value
        #expect(!value.contains("="))
        #expect(!value.contains("+"))
        #expect(!value.contains("/"))
    }

    @Test func matchesExactValue() {
        #expect(OAuthState(value: "abc123").matches("abc123"))
    }

    @Test func rejectsMismatch() {
        let state = OAuthState(value: "abc123")
        #expect(!state.matches("abc124"))  // same length, different content
        #expect(!state.matches("abc12"))   // shorter
        #expect(!state.matches(""))        // empty
    }

    @Test func generatedStatesAreUnique() {
        var seen = Set<String>()
        for _ in 0..<1000 {
            let value = OAuthState.generate().value
            #expect(!seen.contains(value))
            seen.insert(value)
        }
    }
}

@Suite struct ConstantTimeTests {
    @Test func equalsHandlesEqualUnequalAndLengths() {
        #expect(ConstantTime.equals("hello", "hello"))
        #expect(ConstantTime.equals("", ""))
        #expect(!ConstantTime.equals("hello", "world"))
        #expect(!ConstantTime.equals("hello", "hell"))  // differing length
    }
}
