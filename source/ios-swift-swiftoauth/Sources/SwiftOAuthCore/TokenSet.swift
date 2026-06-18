// Source: RFC 6749 §5.1 (token response) + RFC 6750 §2.1 (bearer usage).
import Foundation

/// An OAuth 2.0 token response (RFC 6749 §5.1) plus the bookkeeping swiftoauth
/// needs to persist and later refresh it.
///
/// `Codable` for the on-disk token store; `description` is overridden so the
/// secret material is never printed by accident.
public struct TokenSet: Codable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let refreshToken: String?
    public let scope: String?
    /// Lifetime in seconds as reported by the token response, if any.
    public let expiresIn: Int?
    /// When swiftoauth received the token (used to compute absolute expiry).
    public let obtainedAt: Date
    public let providerID: String

    public init(
        accessToken: String,
        tokenType: String,
        refreshToken: String? = nil,
        scope: String? = nil,
        expiresIn: Int? = nil,
        obtainedAt: Date = Date(),
        providerID: String
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.scope = scope
        self.expiresIn = expiresIn
        self.obtainedAt = obtainedAt
        self.providerID = providerID
    }

    /// Absolute expiry instant, if the response carried `expires_in`.
    public var expiresAt: Date? {
        expiresIn.map { obtainedAt.addingTimeInterval(TimeInterval($0)) }
    }

    /// Whether the access token is past expiry (within `leeway` seconds).
    /// Tokens without an `expires_in` are treated as non-expiring here.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    /// The RFC 6750 bearer `Authorization` header value for this token.
    public var authorizationHeader: String {
        "Bearer \(accessToken)"
    }
}

extension TokenSet: CustomStringConvertible {
    /// Never prints secret material — access and refresh tokens are redacted.
    public var description: String {
        let expiry = expiresAt.map { String(describing: $0) } ?? "nil"
        return "TokenSet(provider: \(providerID), tokenType: \(tokenType), "
            + "accessToken: \(Redaction.redactToken(accessToken)), "
            + "refreshToken: \(refreshToken.map { _ in Redaction.placeholder } ?? "nil"), "
            + "scope: \(scope ?? "nil"), expiresAt: \(expiry))"
    }
}
