// Content — a single content block in a Message.
//
// Wire shape: discriminated by a `type` field. swiftpi uses an enum here
// instead of a struct-with-optional-fields so the type system catches
// missing-case bugs at compile time.

import Foundation

public enum Content: Sendable, Equatable {
    /// Plain UTF-8 text. The most common block type.
    case text(String)

    /// Image input. `swiftpi` doesn't render images itself — providers
    /// pass the source through to the LLM as-is.
    case image(ImageSource)

    /// A tool invocation request emitted by the assistant. The `input`
    /// payload is opaque JSON whose schema is determined by the matching
    /// `ToolDef`.
    case toolUse(id: String, name: String, input: JSONValue)

    /// A tool execution result fed back to the assistant on the next
    /// turn. `content` is itself a list of content blocks (typically a
    /// single `.text`).
    case toolResult(toolUseId: String, content: [Content], isError: Bool)

    /// Extended-thinking output from the assistant. The `signature`,
    /// when present, lets a provider verify the thinking block on a
    /// subsequent turn.
    case thinking(text: String, signature: String?)
}

// MARK: - Codable

extension Content: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
        case id
        case name
        case input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
        case thinking
        case signature
    }

    private enum DiscriminatorValue: String {
        case text
        case image
        case toolUse = "tool_use"
        case toolResult = "tool_result"
        case thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let kind = DiscriminatorValue(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(rawType)"
            )
        }
        switch kind {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .image:
            let source = try container.decode(ImageSource.self, forKey: .source)
            self = .image(source)
        case .toolUse:
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(JSONValue.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case .toolResult:
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let content = try container.decode([Content].self, forKey: .content)
            let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self = .toolResult(toolUseId: toolUseId, content: content, isError: isError)
        case .thinking:
            let text = try container.decode(String.self, forKey: .thinking)
            let signature = try container.decodeIfPresent(String.self, forKey: .signature)
            self = .thinking(text: text, signature: signature)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(DiscriminatorValue.text.rawValue, forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let source):
            try container.encode(DiscriminatorValue.image.rawValue, forKey: .type)
            try container.encode(source, forKey: .source)
        case .toolUse(let id, let name, let input):
            try container.encode(DiscriminatorValue.toolUse.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try container.encode(DiscriminatorValue.toolResult.rawValue, forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
            // Encode `is_error` only when true, mirroring upstream's
            // "omit when false" convention to avoid bloating session files.
            if isError {
                try container.encode(true, forKey: .isError)
            }
        case .thinking(let text, let signature):
            try container.encode(DiscriminatorValue.thinking.rawValue, forKey: .type)
            try container.encode(text, forKey: .thinking)
            try container.encodeIfPresent(signature, forKey: .signature)
        }
    }
}

// MARK: - ImageSource

/// The `source` payload of an `image` content block. Anthropic accepts two
/// shapes: a base64-encoded inline image, or a URL reference. `swiftpi`
/// keeps both fields optional so the same Swift type round-trips either.
public struct ImageSource: Codable, Sendable, Equatable {
    public let type: String
    public let mediaType: String?
    public let data: String?
    public let url: String?

    public init(
        type: String,
        mediaType: String? = nil,
        data: String? = nil,
        url: String? = nil
    ) {
        self.type = type
        self.mediaType = mediaType
        self.data = data
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
        case url
    }
}
