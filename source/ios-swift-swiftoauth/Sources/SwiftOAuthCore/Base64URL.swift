// Source: RFC 4648 §5 — The Base 16, Base 32, and Base 64 Data Encodings
//         (base64url alphabet, used unpadded by RFC 7636 PKCE).
import Foundation

/// base64url (RFC 4648 §5) encoding **without** trailing `=` padding, as
/// required by RFC 7636 for the PKCE `code_challenge` and used throughout
/// swiftoauth for high-entropy URL-safe tokens.
public enum Base64URL {
    /// Encode raw bytes as unpadded base64url.
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var s = Data(bytes).base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    /// Decode an (optionally padded) base64url string back to bytes.
    /// Returns `nil` if the input is not valid base64url.
    public static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s)
    }
}
