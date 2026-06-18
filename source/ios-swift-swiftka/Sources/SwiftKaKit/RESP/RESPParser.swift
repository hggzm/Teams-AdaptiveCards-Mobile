import Foundation

/// Errors raised by ``RESPParser``.
public enum RESPParseError: Swift.Error, Equatable {
    /// Unknown leading type byte (must be one of `+ - : $ *`).
    case unknownType(UInt8)
    /// Length / integer field could not be parsed as base-10.
    case invalidNumber(String)
    /// A bulk string's announced length disagreed with the bytes that
    /// followed (e.g. missing terminator).
    case malformedBulkString
    /// An array's announced count was negative but not the well-known
    /// `-1` sentinel for "nil array".
    case malformedArray
}

/// Streaming-friendly RESP2 parser.
///
/// Holds a private buffer; callers feed bytes via ``feed(_:)`` and pop
/// completed frames with ``next()``. This is the shape SwiftNIO will
/// want in Phase 4: a `ChannelHandler` can append to the parser as
/// `ByteBuffer` chunks arrive and drain whole values when ready.
public final class RESPParser {
    private var buffer: [UInt8] = []
    private var cursor: Int = 0

    public init() {}

    /// Appends raw bytes to the internal buffer.
    public func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    /// Pops the next complete RESP value from the buffer, or returns
    /// `nil` if more bytes are needed.
    public func next() throws -> RESPValue? {
        let start = cursor
        guard let value = try parseValue() else {
            cursor = start
            return nil
        }
        compact()
        return value
    }

    /// Returns true if no buffered bytes remain unconsumed.
    public var isEmpty: Bool { cursor >= buffer.count }

    // MARK: - Internal parsing

    private func parseValue() throws -> RESPValue? {
        guard cursor < buffer.count else { return nil }
        let type = buffer[cursor]
        cursor += 1
        switch type {
        case 0x2B /* + */: return try parseSimpleString().map(RESPValue.simpleString)
        case 0x2D /* - */: return try parseSimpleString().map(RESPValue.error)
        case 0x3A /* : */: return try parseInteger().map(RESPValue.integer)
        case 0x24 /* $ */: return try parseBulkString()
        case 0x2A /* * */: return try parseArray()
        // RESP3 additions.
        case 0x25 /* % */: return try parseMap()
        case 0x7E /* ~ */: return try parseSet()
        case 0x5F /* _ */:
            guard readLine() != nil else { return nil }
            return .null
        case 0x23 /* # */:
            guard let bytes = readLine() else { return nil }
            return .boolean(bytes.first == 0x74) // 't'
        case 0x2C /* , */:
            guard let bytes = readLine() else { return nil }
            let s = String(decoding: bytes, as: UTF8.self).lowercased()
            switch s {
            case "inf", "+inf": return .double(.infinity)
            case "-inf":         return .double(-.infinity)
            case "nan":          return .double(.nan)
            default:
                if let d = Double(s) { return .double(d) }
                throw RESPParseError.invalidNumber(s)
            }
        case 0x28 /* ( */:
            guard let bytes = readLine() else { return nil }
            return .bigNumber(String(decoding: bytes, as: UTF8.self))
        case 0x3D /* = */:
            return try parseVerbatim()
        case 0x3E /* > */:
            return try parsePush()
        default: throw RESPParseError.unknownType(type)
        }
    }

    private func parseMap() throws -> RESPValue? {
        guard let bytes = readLine() else { return nil }
        let header = String(decoding: bytes, as: UTF8.self)
        guard let count = Int(header) else {
            throw RESPParseError.invalidNumber(header)
        }
        if count < 0 { throw RESPParseError.malformedArray }
        var pairs: [RESPKeyValue] = []
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            guard let k = try parseValue() else { return nil }
            guard let v = try parseValue() else { return nil }
            pairs.append(RESPKeyValue(k, v))
        }
        return .map(pairs)
    }

    private func parseSet() throws -> RESPValue? {
        guard let bytes = readLine() else { return nil }
        let header = String(decoding: bytes, as: UTF8.self)
        guard let count = Int(header) else {
            throw RESPParseError.invalidNumber(header)
        }
        if count < 0 { throw RESPParseError.malformedArray }
        var items: [RESPValue] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let item = try parseValue() else { return nil }
            items.append(item)
        }
        return .set(items)
    }

    private func parseVerbatim() throws -> RESPValue? {
        // =<len>\r\n<3-char fmt>:<payload>\r\n
        guard let bytes = readLine() else { return nil }
        let header = String(decoding: bytes, as: UTF8.self)
        guard let length = Int(header), length >= 4 else {
            throw RESPParseError.invalidNumber(header)
        }
        let need = length + 2
        guard cursor + need <= buffer.count else { return nil }
        let format = String(decoding: buffer[cursor..<(cursor + 3)], as: UTF8.self)
        guard buffer[cursor + 3] == 0x3A /* : */ else {
            throw RESPParseError.malformedBulkString
        }
        let payloadStart = cursor + 4
        let payloadLen = length - 4
        let payload = Data(buffer[payloadStart..<(payloadStart + payloadLen)])
        cursor += need
        return .verbatimString(format, payload)
    }

    private func parsePush() throws -> RESPValue? {
        guard let bytes = readLine() else { return nil }
        let header = String(decoding: bytes, as: UTF8.self)
        guard let count = Int(header) else {
            throw RESPParseError.invalidNumber(header)
        }
        if count < 0 { throw RESPParseError.malformedArray }
        var items: [RESPValue] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let item = try parseValue() else { return nil }
            items.append(item)
        }
        return .push(items)
    }

    /// Reads up to (but not including) the next `\r\n`. Returns nil if
    /// the terminator hasn't arrived yet.
    private func readLine() -> [UInt8]? {
        var i = cursor
        while i + 1 < buffer.count {
            if buffer[i] == 0x0D /* \r */ && buffer[i + 1] == 0x0A /* \n */ {
                let line = Array(buffer[cursor..<i])
                cursor = i + 2
                return line
            }
            i += 1
        }
        return nil
    }

    private func parseSimpleString() throws -> String? {
        guard let bytes = readLine() else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func parseInteger() throws -> Int64? {
        guard let bytes = readLine() else { return nil }
        let s = String(decoding: bytes, as: UTF8.self)
        guard let v = Int64(s) else { throw RESPParseError.invalidNumber(s) }
        return v
    }

    private func parseBulkString() throws -> RESPValue? {
        guard let bytes = readLine() else { return nil }
        let header = String(decoding: bytes, as: UTF8.self)
        guard let length = Int(header) else {
            throw RESPParseError.invalidNumber(header)
        }
        if length == -1 { return .bulkString(nil) }
        if length < 0 { throw RESPParseError.malformedBulkString }
        // Need `length` bytes followed by \r\n.
        let need = length + 2
        guard cursor + need <= buffer.count else { return nil }
        let payload = Array(buffer[cursor..<(cursor + length)])
        let trailing = buffer[(cursor + length)..<(cursor + length + 2)]
        guard trailing[trailing.startIndex] == 0x0D,
              trailing[trailing.startIndex + 1] == 0x0A else {
            throw RESPParseError.malformedBulkString
        }
        cursor += need
        return .bulkString(Data(payload))
    }

    private func parseArray() throws -> RESPValue? {
        guard let bytes = readLine() else { return nil }
        let header = String(decoding: bytes, as: UTF8.self)
        guard let count = Int(header) else {
            throw RESPParseError.invalidNumber(header)
        }
        if count == -1 { return .array(nil) }
        if count < 0 { throw RESPParseError.malformedArray }
        var items: [RESPValue] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let item = try parseValue() else { return nil }
            items.append(item)
        }
        return .array(items)
    }

    /// Drops already-consumed bytes from the head of the buffer when
    /// the consumed prefix grows large, to bound memory use.
    private func compact() {
        // Only compact periodically to avoid quadratic behavior under
        // a steady stream of small commands.
        if cursor > 4096 || cursor == buffer.count {
            buffer.removeFirst(cursor)
            cursor = 0
        }
    }
}
