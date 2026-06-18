// Source: RFC 7636 — Proof Key for Code Exchange by OAuth Public Clients.
//   §4.1 code_verifier, §4.2 code_challenge (S256), Appendix B test vector.
import Foundation
import Crypto

/// PKCE (RFC 7636) parameters for the authorization-code flow.
///
/// Only the **S256** challenge method is supported. `plain` is deliberately
/// omitted — S256 is the only method swiftoauth will ever send.
public struct PKCE: Sendable, Equatable {
    /// High-entropy `code_verifier` (RFC 7636 §4.1): 43–128 characters from
    /// the unreserved set `A–Z a–z 0–9 - . _ ~`.
    public let codeVerifier: String

    /// `code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`
    /// (RFC 7636 §4.2), unpadded.
    public let codeChallenge: String

    /// Always `"S256"`.
    public let method: String

    /// Wrap an existing verifier, deriving its S256 challenge.
    public init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = PKCE.challenge(for: codeVerifier)
        self.method = "S256"
    }

    /// Generate a fresh PKCE pair from a cryptographically random verifier.
    ///
    /// - Parameter verifierByteCount: entropy in bytes. The default of 32
    ///   produces a 43-character base64url verifier — the RFC-recommended
    ///   minimum. The accepted range maps exactly onto the 43–128 character
    ///   verifier window RFC 7636 §4.1 allows.
    public static func generate(verifierByteCount: Int = 32) -> PKCE {
        precondition(
            verifierByteCount >= 32 && verifierByteCount <= 96,
            "verifierByteCount must map to a 43–128 char verifier (32…96 bytes)"
        )
        let verifier = Base64URL.encode(RandomBytes.generate(count: verifierByteCount))
        return PKCE(codeVerifier: verifier)
    }

    /// Compute the S256 challenge for a verifier (RFC 7636 §4.2).
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Base64URL.encode(digest)
    }

    /// The unreserved characters permitted in a `code_verifier`.
    public static let unreservedCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Whether a string is a syntactically valid `code_verifier`
    /// (RFC 7636 §4.1: 43–128 chars, unreserved set only).
    public static func isValidVerifier(_ verifier: String) -> Bool {
        let length = verifier.count
        guard length >= 43 && length <= 128 else { return false }
        return verifier.allSatisfy { unreservedCharacters.contains($0) }
    }
}
