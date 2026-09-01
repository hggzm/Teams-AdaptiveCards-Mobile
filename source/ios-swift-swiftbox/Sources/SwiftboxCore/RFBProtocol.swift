import Foundation

/// RFB (Remote Framebuffer, a.k.a. VNC) protocol primitives — the pure,
/// byte-level encode/decode that an ``RFBServer`` drives over a transport.
///
/// Kept free of any transport or I/O so the wire format is unit-tested directly
/// (encode a frame → assert the exact bytes; decode a client message from a byte
/// array). Implements the subset RFB 3.8 clients need to display and drive the
/// swiftbox desktop: the `None` security handshake, `Raw` + `CopyRect`
/// framebuffer-update encodings, and the pointer/keyboard/cut-text client
/// messages. Pure `Foundation`, so it runs in the iOS sandbox unchanged.
public enum RFB {
    /// The protocol version this server speaks.
    public static let protocolVersion = "RFB 003.008\n"

    // MARK: Big-endian integer helpers

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
    static func u32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
    static func i32(_ value: Int32) -> [UInt8] {
        let v = UInt32(bitPattern: value)
        return [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
}

/// A cursor over a `[UInt8]` buffer for decoding RFB messages (big-endian).
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw RFBError.malformed("short read") }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    public mutating func u8() throws -> UInt8 { try take(1)[0] }
    public mutating func u16() throws -> Int {
        let b = try take(2); return (Int(b[0]) << 8) | Int(b[1])
    }
    public mutating func u32() throws -> Int {
        let b = try take(4)
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }
    public mutating func i32() throws -> Int32 {
        let b = try take(4)
        let v = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        return Int32(bitPattern: v)
    }
}

public enum RFBError: Error, Equatable {
    case closed
    case malformed(String)
    case unsupported(String)
}

/// An RFB pixel format (the 16-byte `PIXEL_FORMAT` structure). Determines how a
/// ``Color`` is serialized into framebuffer-update pixel data.
public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: Int
    public var greenMax: Int
    public var blueMax: Int
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColor: Bool,
                redMax: Int, greenMax: Int, blueMax: Int,
                redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// The conventional 32-bpp, depth-24 true-color format (little-endian word,
    /// red at shift 16) that virtually every VNC client accepts.
    public static let `default` = RFBPixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
        redMax: 255, greenMax: 255, blueMax: 255,
        redShift: 16, greenShift: 8, blueShift: 0
    )

    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// Serialize the 16-byte on-the-wire structure.
    public func encoded() -> [UInt8] {
        var out: [UInt8] = [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0]
        out += RFB.u16(redMax) + RFB.u16(greenMax) + RFB.u16(blueMax)
        out += [redShift, greenShift, blueShift, 0, 0, 0]   // 3 bytes padding
        return out
    }

    /// Decode the 16-byte structure from `reader`.
    public static func decode(_ reader: inout ByteReader) throws -> RFBPixelFormat {
        let bpp = try reader.u8(), depth = try reader.u8()
        let big = try reader.u8() != 0, truec = try reader.u8() != 0
        let rMax = try reader.u16(), gMax = try reader.u16(), bMax = try reader.u16()
        let rShift = try reader.u8(), gShift = try reader.u8(), bShift = try reader.u8()
        _ = try reader.take(3)   // padding
        return RFBPixelFormat(bitsPerPixel: bpp, depth: depth, bigEndian: big, trueColor: truec,
                              redMax: rMax, greenMax: gMax, blueMax: bMax,
                              redShift: rShift, greenShift: gShift, blueShift: bShift)
    }

    /// Encode a single color into `bytesPerPixel` bytes per this format.
    public func encode(_ color: Color) -> [UInt8] {
        let r = UInt32(Int(color.r) * redMax / 255)
        let g = UInt32(Int(color.g) * greenMax / 255)
        let b = UInt32(Int(color.b) * blueMax / 255)
        let value = (r << redShift) | (g << greenShift) | (b << blueShift)
        let n = bytesPerPixel
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            // Byte i of the value, MSB-first for big-endian, LSB-first otherwise.
            let shift = bigEndian ? (n - 1 - i) * 8 : i * 8
            out[i] = UInt8((value >> UInt32(shift)) & 0xff)
        }
        return out
    }
}

/// A rectangle's pixel encoding within a framebuffer update.
public enum RFBEncoding: Equatable {
    case raw
    case copyRect(srcX: Int, srcY: Int)

    public var code: Int32 {
        switch self {
        case .raw: return 0
        case .copyRect: return 1
        }
    }
}

/// A decoded pointer (mouse/touch) event: button bitmask + position.
public struct RFBPointerEvent: Equatable, Sendable {
    public var buttonMask: UInt8
    public var x: Int
    public var y: Int
    public init(buttonMask: UInt8, x: Int, y: Int) {
        self.buttonMask = buttonMask; self.x = x; self.y = y
    }
}

/// A decoded key event: an X11 keysym and whether it was pressed or released.
public struct RFBKeyEvent: Equatable, Sendable {
    public var keysym: UInt32
    public var down: Bool
    public init(keysym: UInt32, down: Bool) {
        self.keysym = keysym; self.down = down
    }
}

/// The outcome of decoding one client→server message.
public enum RFBClientMessage: Equatable {
    case setPixelFormat(RFBPixelFormat)
    case setEncodings([Int32])
    case framebufferUpdateRequest(incremental: Bool, rect: Rect)
    case key(RFBKeyEvent)
    case pointer(RFBPointerEvent)
    case cutText(String)
}

extension RFB {
    /// Build a `FramebufferUpdate` (server→client) message for `rects`. Each
    /// entry pairs a region with its encoding; `raw` regions read pixels from
    /// `framebuffer` in `format`.
    static func framebufferUpdate(
        rects: [(rect: Rect, encoding: RFBEncoding)],
        framebuffer: Framebuffer,
        format: RFBPixelFormat
    ) -> [UInt8] {
        var out: [UInt8] = [0, 0]                 // message-type 0, padding
        out += u16(rects.count)
        for (rect, encoding) in rects {
            out += u16(rect.x) + u16(rect.y) + u16(rect.width) + u16(rect.height)
            out += i32(encoding.code)
            switch encoding {
            case .raw:
                out.reserveCapacity(out.count + rect.width * rect.height * format.bytesPerPixel)
                for row in rect.y..<rect.maxY {
                    let base = row * framebuffer.width
                    for col in rect.x..<rect.maxX {
                        out += format.encode(Color(packed: framebuffer.pixels[base + col]))
                    }
                }
            case .copyRect(let srcX, let srcY):
                out += u16(srcX) + u16(srcY)
            }
        }
        return out
    }
}
