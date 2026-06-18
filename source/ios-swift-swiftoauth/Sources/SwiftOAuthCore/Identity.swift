import Foundation

/// The minimal, non-secret identity swiftoauth reads back after login to prove
/// a token works (`whoami`). Provider-specific identity payloads are normalized
/// into these fields; `raw` may carry a few selected non-secret extras.
public struct Identity: Codable, Sendable, Equatable {
    public let providerID: String
    /// The provider's stable account identifier.
    public let id: String
    /// Login / handle, if the provider exposes one.
    public let username: String?
    public let displayName: String?
    public let raw: [String: String]?

    public init(
        providerID: String,
        id: String,
        username: String? = nil,
        displayName: String? = nil,
        raw: [String: String]? = nil
    ) {
        self.providerID = providerID
        self.id = id
        self.username = username
        self.displayName = displayName
        self.raw = raw
    }
}
