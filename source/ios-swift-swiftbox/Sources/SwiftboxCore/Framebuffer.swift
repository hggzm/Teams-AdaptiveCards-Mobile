import Foundation

/// A point in framebuffer pixel coordinates (origin top-left).
public struct Point: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// An axis-aligned rectangle in framebuffer pixel coordinates (origin top-left).
///
/// Used both by the ``Framebuffer`` (damage regions, fills) and, later, by the
/// pure-Swift compositor/window manager that paints into it. Pure value type, no
/// platform dependencies.
public struct Rect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    /// Whether `point` lies within the (half-open) rectangle.
    public func contains(_ point: Point) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    /// The smallest rectangle containing both `self` and `other` (ignoring empty
    /// operands). Used to coalesce damage into a single update region.
    public func union(_ other: Rect) -> Rect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = Swift.min(x, other.x)
        let minY = Swift.min(y, other.y)
        let maxX = Swift.max(self.maxX, other.maxX)
        let maxY = Swift.max(self.maxY, other.maxY)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Intersect with `bounds`, returning the clipped rectangle (possibly empty).
    public func clamped(to bounds: Rect) -> Rect {
        let minX = Swift.max(x, bounds.x)
        let minY = Swift.max(y, bounds.y)
        let maxX = Swift.min(self.maxX, bounds.maxX)
        let maxY = Swift.min(self.maxY, bounds.maxY)
        return Rect(x: minX, y: minY, width: Swift.max(0, maxX - minX), height: Swift.max(0, maxY - minY))
    }
}

/// A 24-bit RGB color (the framebuffer ignores alpha; VNC is opaque).
public struct Color: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Pack into the framebuffer's internal `0x00RRGGBB` word.
    public var packed: UInt32 { (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b) }

    /// Unpack from a `0x00RRGGBB` word.
    public init(packed: UInt32) {
        self.r = UInt8((packed >> 16) & 0xff)
        self.g = UInt8((packed >> 8) & 0xff)
        self.b = UInt8(packed & 0xff)
    }

    public static let black = Color(r: 0, g: 0, b: 0)
    public static let white = Color(r: 255, g: 255, b: 255)
    public static let red   = Color(r: 255, g: 0, b: 0)
    public static let green = Color(r: 0, g: 255, b: 0)
    public static let blue  = Color(r: 0, g: 0, b: 255)
}

/// A pure-Swift software framebuffer: a width×height grid of 24-bit pixels with
/// coalesced damage tracking.
///
/// This is the keystone surface of the swiftbox desktop (ROADMAP Phase 6): the
/// compositor and window manager paint into it, and an ``RFBServer`` serves it
/// over VNC so it can be displayed on any platform — including the iOS sandbox —
/// with no platform windowing code. It owns no I/O and imports only `Foundation`,
/// so it builds and is fully testable everywhere Swift runs.
public final class Framebuffer {
    public let width: Int
    public let height: Int
    /// Row-major pixels, each `0x00RRGGBB`.
    public private(set) var pixels: [UInt32]
    /// Coalesced damaged region since the last ``takeDamage()``, or `nil` if clean.
    public private(set) var damage: Rect?

    public init(width: Int, height: Int, fill: Color = .black) {
        precondition(width > 0 && height > 0, "framebuffer dimensions must be positive")
        self.width = width
        self.height = height
        self.pixels = [UInt32](repeating: fill.packed, count: width * height)
        // The initial contents are the first thing a client must receive in full.
        self.damage = Rect(x: 0, y: 0, width: width, height: height)
    }

    /// The whole-surface rectangle.
    public var bounds: Rect { Rect(x: 0, y: 0, width: width, height: height) }

    /// Read the pixel at `(x, y)`, or `nil` if out of bounds.
    public func pixel(atX x: Int, y: Int) -> Color? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return Color(packed: pixels[y * width + x])
    }

    /// Set the pixel at `(x, y)` (no-op if out of bounds), marking it damaged.
    public func setPixel(x: Int, y: Int, to color: Color) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color.packed
        markDamaged(Rect(x: x, y: y, width: 1, height: 1))
    }

    /// Fill `rect` (clipped to bounds) with `color`.
    public func fill(_ rect: Rect, with color: Color) {
        let r = rect.clamped(to: bounds)
        guard !r.isEmpty else { return }
        let value = color.packed
        for row in r.y..<r.maxY {
            let base = row * width
            for col in r.x..<r.maxX { pixels[base + col] = value }
        }
        markDamaged(r)
    }

    /// Fill the entire surface with `color`.
    public func clear(_ color: Color = .black) {
        let value = color.packed
        for i in pixels.indices { pixels[i] = value }
        markDamaged(bounds)
    }

    /// Copy `source` onto this framebuffer with its top-left at `(x, y)`,
    /// clipping to bounds.
    public func blit(_ source: Framebuffer, x: Int, y: Int) {
        let target = Rect(x: x, y: y, width: source.width, height: source.height).clamped(to: bounds)
        guard !target.isEmpty else { return }
        for row in target.y..<target.maxY {
            let srcRow = row - y
            let dstBase = row * width
            let srcBase = srcRow * source.width
            for col in target.x..<target.maxX {
                pixels[dstBase + col] = source.pixels[srcBase + (col - x)]
            }
        }
        markDamaged(target)
    }

    /// Expand the coalesced damage region by `rect` (clipped to bounds).
    public func markDamaged(_ rect: Rect) {
        let r = rect.clamped(to: bounds)
        guard !r.isEmpty else { return }
        damage = damage?.union(r) ?? r
    }

    /// Return the current damage region (clamped to bounds) and clear it. The
    /// ``RFBServer`` calls this to decide what to send in an incremental update.
    @discardableResult
    public func takeDamage() -> Rect? {
        defer { damage = nil }
        return damage
    }
}
