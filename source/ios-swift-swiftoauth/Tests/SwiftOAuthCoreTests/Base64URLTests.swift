import Testing
import Foundation
@testable import SwiftOAuthCore

@Suite struct Base64URLTests {
    /// RFC 4648 §10 test vectors, rendered as unpadded base64url.
    @Test func rfc4648Vectors() {
        #expect(Base64URL.encode(Data("".utf8)) == "")
        #expect(Base64URL.encode(Data("f".utf8)) == "Zg")
        #expect(Base64URL.encode(Data("fo".utf8)) == "Zm8")
        #expect(Base64URL.encode(Data("foo".utf8)) == "Zm9v")
        #expect(Base64URL.encode(Data("foob".utf8)) == "Zm9vYg")
        #expect(Base64URL.encode(Data("fooba".utf8)) == "Zm9vYmE")
        #expect(Base64URL.encode(Data("foobar".utf8)) == "Zm9vYmFy")
    }

    @Test func neverEmitsPadding() {
        for n in 0..<40 {
            #expect(!Base64URL.encode(RandomBytes.generate(count: n)).contains("="))
        }
    }

    @Test func usesUrlSafeAlphabetOnly() {
        for n in 0..<40 {
            let encoded = Base64URL.encode(RandomBytes.generate(count: n))
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
        }
    }

    @Test func roundTripsThroughDecode() {
        for n in 0..<64 {
            let bytes = RandomBytes.generate(count: n)
            #expect(Base64URL.decode(Base64URL.encode(bytes)) == Data(bytes))
        }
    }
}
