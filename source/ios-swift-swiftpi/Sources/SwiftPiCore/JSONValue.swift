// JSONValue — a Codable representation of an arbitrary JSON value.
//
// `swiftpi` deliberately uses opaque JSONValue payloads at API boundaries
// where the upstream wire shape is dynamic (tool inputs, JSON schemas,
// SSE delta interiors). Tightening these into stronger Swift types is a
// per-phase decision, not a Phase 1 requirement.

import Foundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Bool before Int, because some JSON encoders surface `true`/`false`
        // before numbers; both decoders below are strict against the wrong
        // kind, but ordering is the documented convention.
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
            return
        }
        if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSONValue: unrecognized JSON shape"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let dictionary):
            try container.encode(dictionary)
        }
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    /// `true` when the value is the JSON `null` literal.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Unwrap as a string when the underlying case is `.string`.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Unwrap as a 64-bit signed integer when the underlying case is `.int`.
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// Unwrap as a double; promotes a stored `.int` to a double if present.
    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    /// Unwrap as a bool when the underlying case is `.bool`.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Unwrap as an array when the underlying case is `.array`.
    public var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// Unwrap as an object when the underlying case is `.object`.
    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}
