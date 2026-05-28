// Message — one entry in a conversation history.
//
// Sessions are tree-structured (each message names its parent). Phase 3's
// SwiftPiSession layer walks the tree; SwiftPiCore only models the node.

import Foundation

public struct Message: Codable, Sendable, Equatable {
    /// Stable identifier for this message within its session.
    public let id: String

    /// Speaker.
    public let role: Role

    /// Ordered list of content blocks. A message with no blocks is legal
    /// (e.g. a `model_change` placeholder), but the conventional shape
    /// for an assistant or user turn is at least one block.
    public let content: [Content]

    /// Parent message id. The root message of a session has `nil` here.
    /// Branches share the same parent id; tree-walking code resolves which
    /// branch is the active tip.
    public let parent: String?

    /// Wall-clock timestamp the message entered the session. Optional so
    /// that test fixtures and golden files can omit it.
    public let timestamp: Date?

    public init(
        id: String,
        role: Role,
        content: [Content],
        parent: String? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.parent = parent
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case parent
        case timestamp
    }
}
