import Foundation

/// A built-in desktop application: it paints its current state into a window's
/// content ``Framebuffer`` (ROADMAP Phase 6.3). Keeping apps as pure renderers
/// over the existing engine (the terminal over ``TerminalEmulator``/``Session``,
/// the file manager over ``VirtualFileSystem``) means the whole windowed desktop
/// is headless-testable and runs identically on desktop, WSL, or the iOS sandbox.
public protocol DesktopApp: AnyObject {
    /// The title the compositor shows in the window's title bar.
    var windowTitle: String { get }
    /// Paint the app's current view into its window content surface, top-left at
    /// `(0, 0)`. Called whenever the app's state changes.
    func render(into framebuffer: Framebuffer)
    /// Handle a key event delivered to the focused window (see ``DesktopServer``).
    /// Defaults to ignoring input; interactive apps override it.
    func handleKey(_ event: RFBKeyEvent)
}

public extension DesktopApp {
    func handleKey(_ event: RFBKeyEvent) {}
}

/// Shared text metrics for the built-in apps (one ``BitmapFont`` cell + padding).
public enum DesktopMetrics {
    /// Pixels per character column (the font's advance).
    public static let cellWidth = BitmapFont.advance        // 6
    /// Pixels per text row (glyph height + 2 px leading).
    public static let cellHeight = BitmapFont.glyphHeight + 2 // 9

    /// The content width that exactly fits `columns` character columns.
    public static func contentWidth(columns: Int) -> Int { columns * cellWidth + 2 }
    /// The content height that exactly fits `rows` text rows.
    public static func contentHeight(rows: Int) -> Int { rows * cellHeight + 2 }
}

/// A terminal window app: renders a ``TerminalEmulator``'s character grid into a
/// window, with a block cursor. Feed it bytes (e.g. from a ``Session``) and
/// re-render. This is the desktop face of the same terminal that runs in the
/// console and on iOS.
public final class TerminalApp: DesktopApp {
    public let windowTitle: String
    public let emulator: TerminalEmulator
    public var background: Color
    public var foreground: Color
    public var cursorColor: Color
    public var showCursor: Bool = true

    public init(
        title: String = "Terminal",
        emulator: TerminalEmulator,
        background: Color = Color(r: 16, g: 16, b: 20),
        foreground: Color = Color(r: 220, g: 220, b: 220),
        cursorColor: Color = Color(r: 120, g: 200, b: 120)
    ) {
        self.windowTitle = title
        self.emulator = emulator
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
    }

    /// The content size that fits this terminal's grid exactly.
    public var contentSize: (width: Int, height: Int) {
        (DesktopMetrics.contentWidth(columns: emulator.columns),
         DesktopMetrics.contentHeight(rows: emulator.rows))
    }

    /// Feed bytes to the underlying emulator (convenience passthrough).
    public func feed(_ text: String) { emulator.feed(text) }

    /// Typing into the focused terminal: printable characters, Enter (newline),
    /// and Tab are fed to the emulator so they appear on screen. (Arrows /
    /// backspace need a shell behind the emulator; ignored until one is wired.)
    public func handleKey(_ event: RFBKeyEvent) {
        guard event.down else { return }
        switch RFBKeysym.decode(event.keysym) {
        case .character(let c): feed(String(c))
        case .enter:            feed("\n")
        case .tab:              feed("\t")
        default:                break
        }
    }

    public func render(into framebuffer: Framebuffer) {
        framebuffer.fill(framebuffer.bounds, with: background)
        for row in 0..<emulator.rows {
            let line = emulator.line(row)
            let y = row * DesktopMetrics.cellHeight + 1
            framebuffer.drawText(line, x: 1, y: y, color: foreground)
        }
        guard showCursor else { return }
        // Block cursor: fill the cell, then redraw its glyph in the background
        // color so the character stays legible "inverted".
        let cx = emulator.cursorColumn * DesktopMetrics.cellWidth + 1
        let cy = emulator.cursorRow * DesktopMetrics.cellHeight + 1
        framebuffer.fill(Rect(x: cx, y: cy, width: DesktopMetrics.cellWidth, height: DesktopMetrics.cellHeight),
                         with: cursorColor)
        let row = emulator.line(emulator.cursorRow)
        if emulator.cursorColumn < row.count {
            let ch = row[row.index(row.startIndex, offsetBy: emulator.cursorColumn)]
            framebuffer.drawText(String(ch), x: cx, y: cy, color: background)
        }
    }
}

/// A file-manager window app: lists a ``VirtualFileSystem`` directory, with a
/// movable selection and directory navigation, painted into a window. Directories
/// sort first and show a trailing `/`; `..` appears for any non-root directory.
public final class FileManagerApp: DesktopApp {
    public let windowTitle: String
    public let vfs: VirtualFileSystem
    public private(set) var path: String
    public private(set) var selection: Int = 0

    public var background = Color(r: 28, g: 30, b: 38)
    public var foreground = Color(r: 220, g: 220, b: 220)
    public var directoryColor = Color(r: 120, g: 170, b: 240)
    public var headerColor = Color(r: 160, g: 160, b: 170)
    public var selectionColor = Color(r: 52, g: 101, b: 164)

    /// Fired when the user activates (opens) a regular file, with its full path.
    public var onOpenFile: ((String) -> Void)?

    public init(title: String = "Files", vfs: VirtualFileSystem, path: String = "/") {
        self.windowTitle = title
        self.vfs = vfs
        self.path = FileManagerApp.normalize(path)
    }

    /// A directory entry as displayed: name and whether it is a directory.
    public struct Item: Equatable {
        public let name: String
        public let isDirectory: Bool
    }

    /// The current directory's items: `..` first (unless at root), then
    /// directories, then files — each group alphabetical.
    public func items() -> [Item] {
        var out: [Item] = []
        if path != "/" { out.append(Item(name: "..", isDirectory: true)) }
        let names = (try? vfs.list(path)) ?? []
        let mapped = names.map { Item(name: $0, isDirectory: vfs.isDirectory(childPath($0))) }
        let dirs = mapped.filter { $0.isDirectory }.sorted { $0.name < $1.name }
        let files = mapped.filter { !$0.isDirectory }.sorted { $0.name < $1.name }
        out += dirs + files
        return out
    }

    /// The full VFS path of `name` within the current directory.
    public func childPath(_ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }

    // MARK: Navigation

    public func selectNext() { clampSelection(selection + 1) }
    public func selectPrevious() { clampSelection(selection - 1) }

    private func clampSelection(_ value: Int) {
        let count = items().count
        guard count > 0 else { selection = 0; return }
        selection = min(max(0, value), count - 1)
    }

    /// Activate the selected item: enter a directory (or go up for `..`), or fire
    /// ``onOpenFile`` for a regular file.
    public func activate() {
        let list = items()
        guard selection < list.count else { return }
        let item = list[selection]
        if item.name == ".." {
            goUp()
        } else if item.isDirectory {
            path = childPath(item.name)
            selection = 0
        } else {
            onOpenFile?(childPath(item.name))
        }
    }

    /// Move to the parent directory.
    public func goUp() {
        guard path != "/" else { return }
        var comps = path.split(separator: "/").map(String.init)
        comps.removeLast()
        path = comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
        selection = 0
    }

    /// Keyboard navigation: Up/Down move the selection, Enter activates it.
    public func handleKey(_ event: RFBKeyEvent) {
        guard event.down else { return }
        switch RFBKeysym.decode(event.keysym) {
        case .up:    selectPrevious()
        case .down:  selectNext()
        case .enter: activate()
        default:     break
        }
    }

    private static func normalize(_ path: String) -> String {
        if path.isEmpty || path == "/" { return "/" }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public func render(into framebuffer: Framebuffer) {
        framebuffer.fill(framebuffer.bounds, with: background)
        // Header: the current path, truncated to fit.
        framebuffer.drawText(path, x: 1, y: 1, color: headerColor)

        let rowHeight = DesktopMetrics.cellHeight
        let list = items()
        for (index, item) in list.enumerated() {
            let y = (index + 1) * rowHeight + 1
            if y + BitmapFont.glyphHeight > framebuffer.height { break }   // clip to window
            if index == selection {
                framebuffer.fill(Rect(x: 0, y: y - 1, width: framebuffer.width, height: rowHeight),
                                 with: selectionColor)
            }
            let label = item.isDirectory ? item.name + "/" : item.name
            let color = item.isDirectory ? directoryColor : foreground
            framebuffer.drawText(label, x: 2, y: y, color: color)
        }
    }
}

public extension DesktopCompositor {
    /// Create a window bound to a ``DesktopApp`` (titled by the app) and paint the
    /// app's initial view into it. The returned window's `content` is the app's
    /// surface; re-call `app.render(into: window.content)` after state changes,
    /// then `render()` to recomposite.
    @discardableResult
    func addWindow(app: DesktopApp, origin: Point, contentWidth: Int, contentHeight: Int) -> Window {
        let window = addWindow(title: app.windowTitle, origin: origin,
                               contentWidth: contentWidth, contentHeight: contentHeight)
        app.render(into: window.content)
        return window
    }
}
