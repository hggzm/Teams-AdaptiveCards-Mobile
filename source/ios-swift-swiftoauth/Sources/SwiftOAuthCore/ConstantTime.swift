import Foundation

/// Constant-time comparison helpers, used for CSRF `state` and token checks so
/// that validation does not leak secret contents through timing.
public enum ConstantTime {
    /// Compare two strings in time independent of their *contents*.
    ///
    /// Differing lengths return `false` immediately (a value's length is not
    /// itself the secret here); equal-length inputs are compared byte-by-byte
    /// with no early-out.
    public static func equals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
