import Foundation

/// Serializes ``RESPValue`` to wire bytes per RESP2 and RESP3.
public enum RESPSerializer {
    /// Encodes a single RESP value to bytes.
    public static func encode(_ value: RESPValue) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    /// Appends a single RESP value to an existing buffer.
    public static func append(_ value: RESPValue, to out: inout Data) {
        switch value {
        case .simpleString(let s):
            out.append(0x2B) // +
            out.append(contentsOf: s.utf8)
            out.append(contentsOf: [0x0D, 0x0A])
        case .error(let s):
            out.append(0x2D) // -
            out.append(contentsOf: s.utf8)
            out.append(contentsOf: [0x0D, 0x0A])
        case .integer(let i):
            out.append(0x3A) // :
            out.append(contentsOf: String(i).utf8)
            out.append(contentsOf: [0x0D, 0x0A])
        case .bulkString(let data):
            out.append(0x24) // $
            if let data = data {
                out.append(contentsOf: String(data.count).utf8)
                out.append(contentsOf: [0x0D, 0x0A])
                out.append(data)
                out.append(contentsOf: [0x0D, 0x0A])
            } else {
                out.append(contentsOf: "-1\r\n".utf8)
            }
        case .array(let items):
            out.append(0x2A) // *
            if let items = items {
                out.append(contentsOf: String(items.count).utf8)
                out.append(contentsOf: [0x0D, 0x0A])
                for item in items { append(item, to: &out) }
            } else {
                out.append(contentsOf: "-1\r\n".utf8)
            }
        // RESP3 additions.
        case .map(let pairs):
            out.append(0x25) // %
            out.append(contentsOf: String(pairs.count).utf8)
            out.append(contentsOf: [0x0D, 0x0A])
            for pair in pairs {
                append(pair.key,   to: &out)
                append(pair.value, to: &out)
            }
        case .set(let items):
            out.append(0x7E) // ~
            out.append(contentsOf: String(items.count).utf8)
            out.append(contentsOf: [0x0D, 0x0A])
            for item in items { append(item, to: &out) }
        case .null:
            out.append(0x5F) // _
            out.append(contentsOf: [0x0D, 0x0A])
        case .boolean(let b):
            out.append(0x23) // #
            out.append(b ? 0x74 : 0x66) // 't' / 'f'
            out.append(contentsOf: [0x0D, 0x0A])
        case .double(let d):
            out.append(0x2C) // ,
            let str: String
            if d.isInfinite { str = d > 0 ? "inf" : "-inf" }
            else if d.isNaN  { str = "nan" }
            else if d == d.rounded() && abs(d) < 1e15 {
                str = String(Int64(d))
            } else {
                str = String(d)
            }
            out.append(contentsOf: str.utf8)
            out.append(contentsOf: [0x0D, 0x0A])
        case .bigNumber(let s):
            out.append(0x28) // (
            out.append(contentsOf: s.utf8)
            out.append(contentsOf: [0x0D, 0x0A])
        case .verbatimString(let format, let payload):
            // =<len>\r\n<3-char-format>:<payload>\r\n
            out.append(0x3D) // =
            let totalLen = 4 + payload.count   // "fmt:" + payload
            out.append(contentsOf: String(totalLen).utf8)
            out.append(contentsOf: [0x0D, 0x0A])
            // Format is 3 ASCII chars; pad/truncate to exactly 3.
            var fmtBytes = Array(format.utf8.prefix(3))
            while fmtBytes.count < 3 { fmtBytes.append(0x20) /* space */ }
            out.append(contentsOf: fmtBytes)
            out.append(0x3A) // :
            out.append(payload)
            out.append(contentsOf: [0x0D, 0x0A])
        case .push(let items):
            out.append(0x3E) // >
            out.append(contentsOf: String(items.count).utf8)
            out.append(contentsOf: [0x0D, 0x0A])
            for item in items { append(item, to: &out) }
        }
    }
}
