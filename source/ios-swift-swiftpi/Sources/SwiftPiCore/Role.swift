// Role — the speaker that authored a message.
//
// Wire format matches Anthropic Messages API: lowercase string discriminator.

public enum Role: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case assistant
    case system
}
