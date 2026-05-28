import Foundation

/// A single value in the Redis Serialization Protocol (RESP2 + RESP3).
///
/// RESP2 has five frame types:
///   - `+OK\r\n`           simple string
///   - `-Err...\r\n`       error
///   - `:42\r\n`           integer
///   - `$6\r\nfoobar\r\n`  bulk string (or `$-1\r\n` = nil)
///   - `*3\r\n...`         array     (or `*-1\r\n` = nil)
///
/// RESP3 (Phase 19) adds:
///   - `%2\r\n...`         map (count = number of key/value pairs)
///   - `~3\r\n...`         set
///   - `_\r\n`             null
///   - `#t\r\n` / `#f\r\n` boolean
///   - `,3.14\r\n`         double
///   - `(1234567890\r\n`   big number (arbitrary precision integer)
///   - `=15\r\ntxt:...\r\n` verbatim string
///   - `>3\r\n...`         push (out-of-band, used for pub/sub)
public indirect enum RESPValue: Equatable, Hashable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    case bulkString(Data?)
    case array([RESPValue]?)
    // RESP3 additions.
    case map([RESPKeyValue])
    case set([RESPValue])
    case null
    case boolean(Bool)
    case double(Double)
    case bigNumber(String)
    case verbatimString(String, Data)   // (format like "txt", payload bytes)
    case push([RESPValue])

    /// Convenience: build a non-nil bulk string from a Swift `String`.
    public static func bulkString(_ s: String) -> RESPValue {
        .bulkString(Data(s.utf8))
    }

    /// Convenience: build a non-nil array.
    public static func array(_ values: [RESPValue]) -> RESPValue {
        .array(Optional<[RESPValue]>.some(values))
    }

    /// Convenience for tests / debugging: render bulk strings as text.
    public var asString: String? {
        switch self {
        case .simpleString(let s), .error(let s):
            return s
        case .bulkString(let data):
            return data.flatMap { String(data: $0, encoding: .utf8) }
        case .integer(let i):
            return String(i)
        case .double(let d): return String(d)
        case .boolean(let b): return b ? "t" : "f"
        case .bigNumber(let s): return s
        case .verbatimString(_, let data): return String(data: data, encoding: .utf8)
        case .null: return nil
        case .array, .map, .set, .push: return nil
        }
    }
}

/// One entry in a RESP3 map. We use a struct (instead of a tuple) so
/// the enum can still be `Equatable`/`Hashable`.
public struct RESPKeyValue: Equatable, Hashable {
    public let key: RESPValue
    public let value: RESPValue
    public init(_ key: RESPValue, _ value: RESPValue) {
        self.key = key
        self.value = value
    }
}
