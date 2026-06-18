import Foundation

/// Errors surfaced by SwiftOAuthCore. Messages never include secret material.
public enum OAuthError: Error, Equatable, Sendable {
    case invalidVerifier
    case stateMismatch
    case missingAuthorizationCode
    case malformedTokenResponse(String)
    case malformedIdentityResponse(String)
    case providerError(code: String, description: String?)
    case unknownProvider(String)
    case missingConfiguration(String)
    case revocationUnavailable(String)
}

extension OAuthError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidVerifier:
            return "PKCE code_verifier is not RFC 7636-valid"
        case .stateMismatch:
            return "OAuth state mismatch (possible CSRF) — rejected"
        case .missingAuthorizationCode:
            return "authorization response carried no code"
        case .malformedTokenResponse(let why):
            return "malformed token response: \(why)"
        case .malformedIdentityResponse(let why):
            return "malformed identity response: \(why)"
        case .providerError(let code, let desc):
            return "provider error \(code)" + (desc.map { ": \($0)" } ?? "")
        case .unknownProvider(let id):
            return "unknown provider '\(id)'"
        case .missingConfiguration(let why):
            return "missing configuration: \(why)"
        case .revocationUnavailable(let why):
            return "token revocation unavailable: \(why)"
        }
    }
}
