// Source: RFC 6749 §10.12 — Cross-Site Request Forgery (the `state` parameter).
import Foundation

/// The CSRF `state` parameter (RFC 6749 §10.12): a fresh, single-use,
/// high-entropy value bound to one authorization request and validated for an
/// exact match when the provider redirects back to the loopback callback.
public struct OAuthState: Sendable, Equatable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// Generate a fresh state from `byteCount` bytes of CSPRNG entropy.
    /// The default of 32 bytes yields a 43-character base64url token
    /// (256 bits of entropy).
    public static func generate(byteCount: Int = 32) -> OAuthState {
        precondition(byteCount >= 16, "state needs at least 128 bits of entropy")
        return OAuthState(value: Base64URL.encode(RandomBytes.generate(count: byteCount)))
    }

    /// Exact, constant-time comparison against the `state` the provider
    /// returned. Any mismatch must be rejected (CSRF defense).
    public func matches(_ returned: String) -> Bool {
        ConstantTime.equals(value, returned)
    }
}
