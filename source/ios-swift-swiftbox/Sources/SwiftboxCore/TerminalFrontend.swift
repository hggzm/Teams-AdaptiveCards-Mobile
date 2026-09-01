import Foundation

/// A sink that renders terminal output and presents it to a user.
///
/// This is the boundary between swiftbox's pure-Swift core and whatever draws
/// the terminal. The headless ``TerminalEmulator`` is the reference
/// implementation used in tests and on the desktop. On Apple platforms the
/// on-device app will provide a ``TerminalFrontend`` backed by a real terminal
/// view (e.g. SwiftTerm's `TerminalView`), so the same ``Session`` drives either
/// one unchanged. Keeping the protocol in the cross-platform core means no
/// Apple-only UI types leak into the engine.
public protocol TerminalFrontend: AnyObject {
    /// Write already-rendered text (which may contain ANSI/VT sequences) to the
    /// display.
    func write(_ text: String)
    /// Clear the visible screen and home the cursor.
    func clearScreen()
}

public extension TerminalFrontend {
    func clearScreen() { write("\u{1b}[2J\u{1b}[H") }
}

extension TerminalEmulator: TerminalFrontend {
    public func write(_ text: String) { feed(text) }
    public func clearScreen() { clear() }
}
