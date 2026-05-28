import Foundation

/// Errors raised by the tool dispatch pipeline.
public enum ToolError: Error, Sendable, Equatable {
    case notFound(String)
    case invalidArguments(String)
    case invocationFailed(String)
}

/// A typed tool callable by an agent. Concrete tools own a Codable
/// `Input`/`Output` pair; `AnyTool` provides the JSON-on-the-wire path
/// used by LLM providers.
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    var name: String { get }
    var description: String { get }
    /// JSON Schema describing `Input`. Hand-written; no schema library
    /// dependency by design.
    var inputSchemaJSON: String { get }

    func invoke(_ input: Input) async throws -> Output
}

public extension Tool {
    var inputSchemaJSON: String { #"{"type":"object"}"# }
}

/// Type-erased tool with a JSON-in / JSON-out invocation surface.
public struct AnyTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String
    private let _invoke: @Sendable (String) async throws -> String

    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.inputSchemaJSON = tool.inputSchemaJSON
        self._invoke = { argsJSON in
            guard let data = argsJSON.data(using: .utf8) else {
                throw ToolError.invalidArguments("arguments are not valid UTF-8")
            }
            let input: T.Input
            do {
                input = try JSONDecoder().decode(T.Input.self, from: data)
            } catch {
                throw ToolError.invalidArguments(String(describing: error))
            }
            let output: T.Output
            do {
                output = try await tool.invoke(input)
            } catch let e as ToolError {
                throw e
            } catch {
                throw ToolError.invocationFailed(String(describing: error))
            }
            let outData = try JSONEncoder().encode(output)
            return String(data: outData, encoding: .utf8) ?? "null"
        }
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        try await _invoke(argumentsJSON)
    }
}

/// Thread-safe registry of tools keyed by name.
public actor ToolRegistry {
    private var tools: [String: AnyTool] = [:]

    public init() {}

    public func register(_ erased: AnyTool) {
        tools[erased.name] = erased
    }

    public func register<T: Tool>(_ tool: T) {
        tools[tool.name] = AnyTool(tool)
    }

    public func get(_ name: String) -> AnyTool? { tools[name] }

    public func names() -> [String] { tools.keys.sorted() }

    public func invoke(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = tools[name] else { throw ToolError.notFound(name) }
        return try await tool.invoke(argumentsJSON: argumentsJSON)
    }
}
