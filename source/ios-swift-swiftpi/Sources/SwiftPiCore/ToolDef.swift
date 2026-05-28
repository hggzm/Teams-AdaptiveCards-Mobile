// ToolDef — the agent-facing definition of a tool the assistant may call.
//
// `inputSchema` is opaque JSON (typically a JSON Schema object). The
// concrete schema validation lives in SwiftPiTools; SwiftPiCore only
// carries the metadata across the agent boundary.

public struct ToolDef: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}
