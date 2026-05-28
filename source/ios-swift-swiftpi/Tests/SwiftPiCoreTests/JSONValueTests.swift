
import Foundation
import Testing
@testable import SwiftPiCore

// MARK: - Test helpers
//
// Wrapped in an enum namespace so that the free function name doesn't
// collide with Swift Testing's per-suite synthesized members. Without
// the namespace, `try roundTrip(value)` inside a `@Test` method resolves
// to a (non-existent) instance method on the suite type and fails to
// compile (Swift 6.3 / swift-testing 0.10+).
enum TestHelpers {
    /// Encode and decode a Codable value to assert lossless round-trip.
    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("null encodes and decodes")
    func nullRoundTrip() throws {
        let value: JSONValue = .null
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == .null)
        #expect(restored.isNull)
    }

    @Test("string accessor and round-trip")
    func stringRoundTrip() throws {
        let value: JSONValue = .string("hello")
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
        #expect(restored.stringValue == "hello")
        #expect(restored.intValue == nil)
    }

    @Test("integer round-trip preserves type")
    func intRoundTrip() throws {
        let value: JSONValue = .int(42)
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == .int(42))
        #expect(restored.intValue == 42)
        #expect(restored.doubleValue == 42.0)
    }

    @Test("double round-trip preserves precision")
    func doubleRoundTrip() throws {
        let value: JSONValue = .double(3.14159)
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == .double(3.14159))
        #expect(restored.doubleValue == 3.14159)
        #expect(restored.intValue == nil)
    }

    @Test("bool round-trips both polarities")
    func boolRoundTrip() throws {
        #expect(try TestHelpers.roundTrip(JSONValue.bool(true)) == .bool(true))
        #expect(try TestHelpers.roundTrip(JSONValue.bool(false)) == .bool(false))
    }

    @Test("nested array of mixed primitives")
    func arrayRoundTrip() throws {
        let value: JSONValue = .array([
            .int(1),
            .string("two"),
            .bool(false),
            .null,
        ])
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
        #expect(restored.arrayValue?.count == 4)
    }

    @Test("nested object with keys round-trips")
    func objectRoundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("read"),
            "limit": .int(2000),
            "enabled": .bool(true),
        ])
        let restored = try TestHelpers.roundTrip(value)
        #expect(restored == value)
        #expect(restored.objectValue?["name"]?.stringValue == "read")
    }

    @Test("decoding a known JSON document into JSONValue")
    func decodeFromRawJSON() throws {
        let raw = #"{"a":1,"b":[true,null,"x"]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(JSONValue.self, from: raw)
        guard let obj = decoded.objectValue else {
            Issue.record("Expected object, got \(decoded)")
            return
        }
        #expect(obj["a"] == .int(1))
        #expect(obj["b"]?.arrayValue?.count == 3)
        #expect(obj["b"]?.arrayValue?[1] == .null)
    }
}
