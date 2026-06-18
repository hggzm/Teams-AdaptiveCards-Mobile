import Foundation

/// Cryptographically secure random bytes.
///
/// Backed by `SystemRandomNumberGenerator`, which Swift documents as suitable
/// for cryptographic use on every supported platform (it wraps the OS CSPRNG:
/// `getrandom`/`/dev/urandom` on Linux, `arc4random` on Apple platforms,
/// `BCryptGenRandom` on Windows). This keeps swiftoauth free of any Apple-only
/// crypto RNG.
public enum RandomBytes {
    /// Return `count` cryptographically random bytes.
    public static func generate(count: Int) -> [UInt8] {
        precondition(count >= 0, "count must be non-negative")
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
    }
}
