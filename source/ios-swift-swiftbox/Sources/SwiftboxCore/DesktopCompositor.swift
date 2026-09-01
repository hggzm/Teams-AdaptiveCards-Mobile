import Foundation

/// A desktop window: a title, a position, and a content ``Framebuffer`` that an
/// application paints into. The compositor draws a title bar above the content
/// and blits the content beneath it.
///
/// Pure model object (no I/O); the ``DesktopCompositor`` owns stacking, focus,
/// and geometry. An app (ROADMAP Phase 6.3) renders into `content` and asks the
/// compositor to recomposite.
public final class Window {
    public let id: Int
    public var title: String
    /// Top-left of the *decorated* window (the title bar's top-left).
    public var origin: Point
    /// The application's pixel surface (its size is the content area).
    public private(set) var content: Framebuffer
    public var isVisible: Bool = true

    public init(id: Int, title: String, origin: Point, content: Framebuffer) {
        self.id = id
        self.title = title
        self.origin = origin
        self.content = content
    }

    /// Replace the content surface (used by ``DesktopCompositor/resizeWindow(id:contentWidth:contentHeight:)``),
    /// blitting the old pixels into the new buffer so visible content is kept.
    func resizeContent(width: Int, height: Int) {
        let next = Framebuffer(width: width, height: height)
        next.blit(content, x: 0, y: 0)
        content = next
    }
}

/// Which part of a window a point falls in.
public enum WindowRegion: Equatable {
    case titleBar
    case content
}

/// An XFCE-ish panel: a thin bar (default: bottom) with a clock on the right and
/// launcher buttons on the left; the compositor also paints a window-list button
/// for each window. Pure layout/state — the compositor renders it and routes
/// clicks.
public struct Panel {
    public var height: Int
    public var atBottom: Bool
    public var background: Color
    public var foreground: Color
    /// Right-aligned clock/status text; the host updates it.
    public var clockText: String
    /// Launcher buttons (label shown, `id` reported to `onLaunch`).
    public var launchers: [(id: String, label: String)]

    public init(
        height: Int = 16,
        atBottom: Bool = true,
        background: Color = Color(r: 40, g: 40, b: 48),
        foreground: Color = .white,
        clockText: String = "",
        launchers: [(id: String, label: String)] = []
    ) {
        self.height = height
        self.atBottom = atBottom
        self.background = background
        self.foreground = foreground
        self.clockText = clockText
        self.launchers = launchers
    }
}

/// A pure-Swift desktop compositor + window manager that paints windows and an
/// XFCE-ish panel into a ``Framebuffer`` (ROADMAP Phase 6.2). It owns stacking
/// (z-order), focus, hit-testing, and title-bar dragging, and translates
/// ``RFBPointerEvent`` input into those operations — so the same desktop, served
/// by an ``RFBServer``, is driven by any VNC client on any platform (desktop,
/// WSL, or the iOS sandbox) with no per-OS windowing code.
public final class DesktopCompositor {
    public let framebuffer: Framebuffer
    public var background: Color
    public let titleBarHeight: Int
    public var panel: Panel

    /// Title-bar colors for the focused vs. unfocused window.
    public var focusedTitleColor = Color(r: 52, g: 101, b: 164)
    public var unfocusedTitleColor = Color(r: 90, g: 90, b: 98)
    public var titleTextColor = Color.white

    /// Windows in back-to-front order; the last element is the top-most.
    public private(set) var windows: [Window] = []
    public private(set) var focusedWindowID: Int?

    /// Fires when a panel launcher button is clicked, with the launcher's `id`.
    public var onLaunch: ((String) -> Void)?

    private var nextID = 1
    private var lastButtonMask: UInt8 = 0
    /// Active title-bar drag: window id + grab offset within the title bar.
    private var drag: (id: Int, offsetX: Int, offsetY: Int)?

    public init(
        framebuffer: Framebuffer,
        background: Color = Color(r: 24, g: 28, b: 36),
        titleBarHeight: Int = 16,
        panel: Panel = Panel()
    ) {
        self.framebuffer = framebuffer
        self.background = background
        self.titleBarHeight = titleBarHeight
        self.panel = panel
    }

    // MARK: - Geometry

    public func titleBarRect(for window: Window) -> Rect {
        Rect(x: window.origin.x, y: window.origin.y, width: window.content.width, height: titleBarHeight)
    }
    public func contentRect(for window: Window) -> Rect {
        Rect(x: window.origin.x, y: window.origin.y + titleBarHeight,
             width: window.content.width, height: window.content.height)
    }
    public func decoratedFrame(for window: Window) -> Rect {
        Rect(x: window.origin.x, y: window.origin.y,
             width: window.content.width, height: titleBarHeight + window.content.height)
    }
    /// The panel's rectangle along the bottom (or top) edge.
    public var panelRect: Rect {
        Rect(x: 0, y: panel.atBottom ? framebuffer.height - panel.height : 0,
             width: framebuffer.width, height: panel.height)
    }

    // MARK: - Window management

    @discardableResult
    public func addWindow(title: String, origin: Point, contentWidth: Int, contentHeight: Int) -> Window {
        let window = Window(id: nextID, title: title, origin: origin,
                            content: Framebuffer(width: contentWidth, height: contentHeight, fill: .white))
        nextID += 1
        windows.append(window)               // top of the stack
        focusedWindowID = window.id
        return window
    }

    public func window(id: Int) -> Window? { windows.first { $0.id == id } }

    public func removeWindow(id: Int) {
        windows.removeAll { $0.id == id }
        if focusedWindowID == id { focusedWindowID = windows.last?.id }
        if drag?.id == id { drag = nil }
    }

    /// Bring `id` to the top of the stack and focus it.
    public func raise(id: Int) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let window = windows.remove(at: index)
        windows.append(window)
        focusedWindowID = id
    }

    public func moveWindow(id: Int, to origin: Point) {
        window(id: id)?.origin = origin
    }

    public func resizeWindow(id: Int, contentWidth: Int, contentHeight: Int) {
        window(id: id)?.resizeContent(width: contentWidth, height: contentHeight)
    }

    /// The top-most window containing `point`, with the region hit, or `nil`.
    public func windowHit(at point: Point) -> (window: Window, region: WindowRegion)? {
        for window in windows.reversed() where window.isVisible {
            if decoratedFrame(for: window).contains(point) {
                let region: WindowRegion = point.y < window.origin.y + titleBarHeight ? .titleBar : .content
                return (window, region)
            }
        }
        return nil
    }

    // MARK: - Input

    /// Translate one pointer event into focus/raise/drag (and panel clicks).
    /// Button bit 0 is the primary button; press and release are edge-detected.
    public func handlePointer(_ event: RFBPointerEvent) {
        let point = Point(x: event.x, y: event.y)
        let down = event.buttonMask & 1 == 1
        let wasDown = lastButtonMask & 1 == 1
        defer { lastButtonMask = event.buttonMask }

        if down && !wasDown {                       // press edge
            if panelRect.contains(point) {
                handlePanelClick(point)
                return
            }
            if let hit = windowHit(at: point) {
                raise(id: hit.window.id)
                if hit.region == .titleBar {
                    drag = (hit.window.id, point.x - hit.window.origin.x, point.y - hit.window.origin.y)
                }
            }
        } else if down && wasDown {                 // drag
            if let drag, let window = window(id: drag.id) {
                window.origin = Point(x: point.x - drag.offsetX, y: point.y - drag.offsetY)
            }
        } else if !down && wasDown {                // release edge
            drag = nil
        }
    }

    private func handlePanelClick(_ point: Point) {
        // Launcher buttons first (left side), then window-list buttons.
        for (rect, item) in panelLauncherLayout() where rect.contains(point) {
            onLaunch?(item.id)
            return
        }
        for (rect, window) in panelWindowListLayout() where rect.contains(point) {
            raise(id: window.id)
            return
        }
    }

    // Panel button layouts (shared by render + hit-testing so they stay in sync).
    private func panelLauncherLayout() -> [(rect: Rect, item: (id: String, label: String))] {
        var x = 2
        let y = panelRect.y + 1
        let h = panel.height - 2
        var out: [(Rect, (id: String, label: String))] = []
        for item in panel.launchers {
            let w = BitmapFont.width(of: item.label) + 6
            out.append((Rect(x: x, y: y, width: w, height: h), item))
            x += w + 3
        }
        return out
    }
    private func panelWindowListLayout() -> [(rect: Rect, window: Window)] {
        var x = panelLauncherLayout().last.map { $0.rect.maxX + 8 } ?? 8
        let y = panelRect.y + 1
        let h = panel.height - 2
        var out: [(Rect, Window)] = []
        for window in windows {
            let w = BitmapFont.width(of: window.title) + 6
            out.append((Rect(x: x, y: y, width: w, height: h), window))
            x += w + 3
        }
        return out
    }

    // MARK: - Rendering

    /// Repaint the whole desktop: background, windows back-to-front (each with a
    /// title bar + its content), then the panel on top.
    public func render() {
        framebuffer.fill(framebuffer.bounds, with: background)

        for window in windows where window.isVisible {
            let focused = window.id == focusedWindowID
            framebuffer.fill(titleBarRect(for: window),
                             with: focused ? focusedTitleColor : unfocusedTitleColor)
            framebuffer.drawText(window.title,
                                 x: window.origin.x + 3,
                                 y: window.origin.y + (titleBarHeight - BitmapFont.glyphHeight) / 2,
                                 color: titleTextColor)
            let cr = contentRect(for: window)
            framebuffer.blit(window.content, x: cr.x, y: cr.y)
        }

        renderPanel()
    }

    private func renderPanel() {
        let bar = panelRect
        framebuffer.fill(bar, with: panel.background)

        for (rect, item) in panelLauncherLayout() {
            framebuffer.fill(rect, with: panel.foreground.dimmed())
            framebuffer.drawText(item.label, x: rect.x + 3,
                                 y: rect.y + (rect.height - BitmapFont.glyphHeight) / 2,
                                 color: panel.background)
        }
        for (rect, window) in panelWindowListLayout() {
            let focused = window.id == focusedWindowID
            framebuffer.fill(rect, with: focused ? focusedTitleColor : unfocusedTitleColor)
            framebuffer.drawText(window.title, x: rect.x + 3,
                                 y: rect.y + (rect.height - BitmapFont.glyphHeight) / 2,
                                 color: panel.foreground)
        }
        if !panel.clockText.isEmpty {
            let w = BitmapFont.width(of: panel.clockText)
            framebuffer.drawText(panel.clockText,
                                 x: bar.maxX - w - 3,
                                 y: bar.y + (panel.height - BitmapFont.glyphHeight) / 2,
                                 color: panel.foreground)
        }
    }
}

extension Color {
    /// A slightly darkened copy (used for raised panel buttons).
    func dimmed(by factor: Double = 0.75) -> Color {
        Color(r: UInt8(Double(r) * factor), g: UInt8(Double(g) * factor), b: UInt8(Double(b) * factor))
    }
}
