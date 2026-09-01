import Foundation

/// A bidirectional byte transport for an ``RFBServer`` session. Abstracted so
/// the server logic is unit-tested over an in-memory buffer with no sockets; a
/// desktop build supplies a TCP-backed implementation.
public protocol RFBTransport: AnyObject {
    /// Read **exactly** `count` bytes, throwing ``RFBError/closed`` at EOF.
    func read(_ count: Int) throws -> [UInt8]
    /// Write all of `bytes`.
    func write(_ bytes: [UInt8]) throws
}

/// An in-memory ``RFBTransport``: the inbound queue is the client→server byte
/// stream (preload it in tests), and everything the server writes is captured in
/// `outbound`. Lets the whole RFB session be exercised deterministically.
public final class InMemoryRFBTransport: RFBTransport {
    public private(set) var inbound: [UInt8]
    public private(set) var outbound: [UInt8] = []
    private var readCursor = 0

    public init(inbound: [UInt8] = []) { self.inbound = inbound }

    /// Append more client bytes to be read (e.g. between handshake and messages).
    public func feed(_ bytes: [UInt8]) { inbound += bytes }

    public func read(_ count: Int) throws -> [UInt8] {
        guard readCursor + count <= inbound.count else { throw RFBError.closed }
        defer { readCursor += count }
        return Array(inbound[readCursor..<readCursor + count])
    }

    public func write(_ bytes: [UInt8]) throws { outbound += bytes }
}

/// An ``RFBTransport`` over byte-stream primitives that may return **partial**
/// reads — exactly how a socket's `recv` behaves. The desktop's TCP listener
/// supplies a `readSome` (return up to `n` bytes; empty = EOF/closed) and a
/// `writeAll`, and this type reassembles the protocol's "read exactly `count`"
/// contract from those partial chunks via an internal buffer.
///
/// Keeping the reassembly here (in the pure, testable core) means the executable
/// target's socket shim is a couple of trivial closures, and the fiddly
/// short-read handling is unit-tested with no sockets.
public final class StreamingRFBTransport: RFBTransport {
    private let readSome: (Int) throws -> [UInt8]
    private let writeAll: ([UInt8]) throws -> Void
    private var buffer: [UInt8] = []

    public init(
        readSome: @escaping (Int) throws -> [UInt8],
        writeAll: @escaping ([UInt8]) throws -> Void
    ) {
        self.readSome = readSome
        self.writeAll = writeAll
    }

    public func read(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        while buffer.count < count {
            let chunk = try readSome(count - buffer.count)
            if chunk.isEmpty { throw RFBError.closed }   // EOF before `count` bytes
            buffer += chunk
        }
        let out = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return out
    }

    public func write(_ bytes: [UInt8]) throws { try writeAll(bytes) }
}


/// A pure-Swift RFB (VNC) server session that exposes a ``Framebuffer`` to a
/// client over an injectable ``RFBTransport``.
///
/// The keystone of the swiftbox desktop (ROADMAP Phase 6): because the server,
/// the framebuffer and the protocol are all pure `Foundation` Swift, the desktop
/// surface can be displayed by any standard VNC client on any platform — desktop,
/// WSL, or the iOS sandbox — without per-OS windowing code. Input arrives as
/// ``RFBPointerEvent``/``RFBKeyEvent`` via the `onPointer`/`onKey` hooks, which
/// the compositor (Phase 6.2) will consume.
public final class RFBServer {
    public let framebuffer: Framebuffer
    public let desktopName: String
    private let transport: RFBTransport

    /// The pixel format in effect (the server advertises ``RFBPixelFormat/default``;
    /// a client may override it with `SetPixelFormat`).
    public private(set) var pixelFormat: RFBPixelFormat = .default
    /// Encodings the client advertised (after `SetEncodings`).
    public private(set) var clientEncodings: [Int32] = []
    /// Whether the client advertised `CopyRect` support.
    public var supportsCopyRect: Bool { clientEncodings.contains(1) }
    public private(set) var didHandshake = false

    public var onPointer: ((RFBPointerEvent) -> Void)?
    public var onKey: ((RFBKeyEvent) -> Void)?
    public var onCutText: ((String) -> Void)?

    public init(framebuffer: Framebuffer, transport: RFBTransport, desktopName: String = "swiftbox") {
        self.framebuffer = framebuffer
        self.transport = transport
        self.desktopName = desktopName
    }

    // MARK: - Handshake

    /// Perform the RFB 3.8 `None`-security handshake through `ServerInit`.
    public func performHandshake() throws {
        // 1. ProtocolVersion: server offers, client echoes its choice.
        try transport.write(Array(RFB.protocolVersion.utf8))
        let clientVersion = try transport.read(12)
        guard clientVersion.starts(with: Array("RFB ".utf8)) else {
            throw RFBError.malformed("bad ProtocolVersion")
        }

        // 2. Security: offer only `None` (type 1); client selects it.
        try transport.write([1, 1])
        let selected = try transport.read(1)[0]
        guard selected == 1 else { throw RFBError.unsupported("security type \(selected)") }
        try transport.write(RFB.u32(0))            // SecurityResult: OK

        // 3. ClientInit (shared-flag) — accepted and ignored.
        _ = try transport.read(1)

        // 4. ServerInit: dimensions, pixel format, desktop name.
        var init_: [UInt8] = RFB.u16(framebuffer.width) + RFB.u16(framebuffer.height)
        init_ += pixelFormat.encoded()
        let name = Array(desktopName.utf8)
        init_ += RFB.u32(name.count) + name
        try transport.write(init_)
        didHandshake = true
    }

    // MARK: - Client messages

    /// Read and dispatch exactly one client→server message. Pointer/key/cut-text
    /// messages also fire the corresponding hook. Throws ``RFBError/closed`` when
    /// the client disconnects.
    @discardableResult
    public func processMessage() throws -> RFBClientMessage {
        let type = try transport.read(1)[0]
        switch type {
        case 0:   // SetPixelFormat
            var r = ByteReader(try transport.read(3 + 16))   // 3 padding + 16 format
            _ = try r.take(3)
            let pf = try RFBPixelFormat.decode(&r)
            pixelFormat = pf
            return .setPixelFormat(pf)

        case 2:   // SetEncodings
            let head = try transport.read(3)                 // 1 padding + 2 count
            var hr = ByteReader(head); _ = try hr.u8()
            let count = try hr.u16()
            var body = ByteReader(try transport.read(count * 4))
            var encs: [Int32] = []
            for _ in 0..<count { encs.append(try body.i32()) }
            clientEncodings = encs
            return .setEncodings(encs)

        case 3:   // FramebufferUpdateRequest
            var r = ByteReader(try transport.read(9))        // incremental + x,y,w,h
            let incremental = try r.u8() != 0
            let rect = Rect(x: try r.u16(), y: try r.u16(), width: try r.u16(), height: try r.u16())
            return .framebufferUpdateRequest(incremental: incremental, rect: rect)

        case 4:   // KeyEvent
            var r = ByteReader(try transport.read(7))        // down + 2 padding + 4 keysym
            let down = try r.u8() != 0
            _ = try r.take(2)
            let event = RFBKeyEvent(keysym: UInt32(try r.u32()), down: down)
            onKey?(event)
            return .key(event)

        case 5:   // PointerEvent
            var r = ByteReader(try transport.read(5))        // buttonMask + x + y
            let event = RFBPointerEvent(buttonMask: try r.u8(), x: try r.u16(), y: try r.u16())
            onPointer?(event)
            return .pointer(event)

        case 6:   // ClientCutText
            var head = ByteReader(try transport.read(7))     // 3 padding + 4 length
            _ = try head.take(3)
            let length = try head.u32()
            let text = String(decoding: try transport.read(length), as: UTF8.self)
            onCutText?(text)
            return .cutText(text)

        default:
            throw RFBError.unsupported("client message type \(type)")
        }
    }

    // MARK: - Framebuffer updates

    /// Send an explicit set of update rectangles.
    public func sendFramebufferUpdate(_ rects: [(rect: Rect, encoding: RFBEncoding)]) throws {
        try transport.write(RFB.framebufferUpdate(rects: rects, framebuffer: framebuffer, format: pixelFormat))
    }

    /// Send the framebuffer's current damage as a single `Raw` rectangle. Returns
    /// `false` (writing nothing) when there is no damage — except that when
    /// `full` is set the entire surface is sent regardless (used to answer a
    /// non-incremental `FramebufferUpdateRequest`).
    @discardableResult
    public func sendDamage(full: Bool = false) throws -> Bool {
        let region: Rect?
        if full {
            _ = framebuffer.takeDamage()
            region = framebuffer.bounds
        } else {
            region = framebuffer.takeDamage()
        }
        guard let rect = region, !rect.isEmpty else { return false }
        try sendFramebufferUpdate([(rect, .raw)])
        return true
    }
}
