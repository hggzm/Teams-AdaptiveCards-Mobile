import Foundation

/// A decoded key from an RFB ``RFBKeyEvent`` keysym: a printable character or a
/// recognized special key. Lets the desktop apps handle input without each one
/// re-decoding X11 keysyms.
public enum RFBKey: Equatable {
    case character(Character)
    case enter
    case backspace
    case tab
    case escape
    case left, right, up, down
    case home, end
    case unknown
}

/// Maps the X11 keysyms carried by an RFB `KeyEvent` to an ``RFBKey``. Covers the
/// printable ASCII range and the common control/navigation keysyms VNC clients
/// send; anything else is `.unknown`.
public enum RFBKeysym {
    public static func decode(_ keysym: UInt32) -> RFBKey {
        switch keysym {
        case 0x20...0x7E:
            return Unicode.Scalar(keysym).map { .character(Character($0)) } ?? .unknown
        case 0xFF0D, 0xFF8D: return .enter        // Return, KP_Enter
        case 0xFF08:         return .backspace
        case 0xFF09:         return .tab
        case 0xFF1B:         return .escape
        case 0xFF51:         return .left
        case 0xFF52:         return .up
        case 0xFF53:         return .right
        case 0xFF54:         return .down
        case 0xFF50:         return .home
        case 0xFF57:         return .end
        default:             return .unknown
        }
    }
}

/// Ties a ``DesktopCompositor`` to an ``RFBServer`` so a VNC client drives the
/// whole desktop end to end (ROADMAP Phase 6.5): pointer events route to the
/// compositor (focus / raise / drag / panel), key events route to the focused
/// window's ``DesktopApp``, and each `FramebufferUpdateRequest` is answered by
/// re-rendering every app into its window, compositing, and sending the damage.
///
/// All pure `Foundation` over the injectable ``RFBTransport`` — so the same
/// server runs over an in-memory transport in tests, a TCP socket on the
/// desktop, or the iOS app's own connection, with no per-OS code here.
public final class DesktopServer {
    public let compositor: DesktopCompositor
    public let rfb: RFBServer
    /// Window id → the app that paints and receives input for it.
    private var apps: [Int: DesktopApp] = [:]

    public init(compositor: DesktopCompositor, transport: RFBTransport, desktopName: String = "swiftbox") {
        self.compositor = compositor
        self.rfb = RFBServer(framebuffer: compositor.framebuffer, transport: transport, desktopName: desktopName)
        rfb.onPointer = { [weak self] in self?.compositor.handlePointer($0) }
        rfb.onKey = { [weak self] in self?.routeKey($0) }
    }

    /// Add an app in its own window and register it for input/render. The window
    /// is titled by the app and its initial view is painted immediately.
    @discardableResult
    public func addApp(_ app: DesktopApp, origin: Point, contentWidth: Int, contentHeight: Int) -> Window {
        let window = compositor.addWindow(app: app, origin: origin,
                                          contentWidth: contentWidth, contentHeight: contentHeight)
        apps[window.id] = app
        return window
    }

    public func app(for windowID: Int) -> DesktopApp? { apps[windowID] }

    /// The app of the currently focused window, if any.
    public var focusedApp: DesktopApp? { compositor.focusedWindowID.flatMap { apps[$0] } }

    /// Number of `FramebufferUpdate` messages sent to the client so far.
    public private(set) var framebufferUpdatesSent = 0

    private func routeKey(_ event: RFBKeyEvent) {
        focusedApp?.handleKey(event)
    }

    /// Repaint: each app renders into its window's content surface, then the
    /// compositor composites windows + panel into the shared framebuffer.
    public func renderAll() {
        for window in compositor.windows {
            apps[window.id]?.render(into: window.content)
        }
        compositor.render()
    }

    /// Perform the RFB handshake and paint the first frame.
    public func start() throws {
        try rfb.performHandshake()
        renderAll()
    }

    /// Process one client message and respond. A `FramebufferUpdateRequest`
    /// triggers a re-render + framebuffer update (full when non-incremental);
    /// pointer/key events (already applied via the hooks during decode) trigger a
    /// re-render so the next update reflects them.
    @discardableResult
    public func processEvent() throws -> RFBClientMessage {
        let message = try rfb.processMessage()
        switch message {
        case .framebufferUpdateRequest(let incremental, _):
            renderAll()
            if try rfb.sendDamage(full: !incremental) { framebufferUpdatesSent += 1 }
        case .pointer, .key:
            renderAll()
        default:
            break
        }
        return message
    }

    /// Handshake, then loop processing client messages until the client
    /// disconnects (``RFBError/closed``).
    public func run() throws {
        try start()
        while true {
            do { _ = try processEvent() }
            catch RFBError.closed { break }
        }
    }
}
