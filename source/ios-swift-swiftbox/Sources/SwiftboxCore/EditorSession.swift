import Foundation

/// An interactive full-screen editor session: it binds a ``VisualEditor`` to a
/// VFS-backed file and a ``TerminalFrontend``, consuming keystrokes and applying
/// the editor's side effects (writing the buffer, quitting).
///
/// This is the visual-mode analogue of ``Session``: the on-device terminal view
/// owns one of these when the user runs `vi <file>`, feeds it the raw keystroke
/// stream, and draws the rendered screen. Keeping it in the pure core means the
/// modal editor is fully testable on the desktop with no UI and no device.
public final class EditorSession {
    public let shell: Shell
    public let frontend: TerminalFrontend
    public let rows: Int
    public let columns: Int
    public private(set) var editor: VisualEditor
    public private(set) var finished = false

    /// The resolved VFS path being edited (nil for a scratch buffer).
    private let path: String?

    public init(
        shell: Shell,
        path: String?,
        frontend: TerminalFrontend,
        rows: Int = 24,
        columns: Int = 80
    ) {
        self.shell = shell
        self.frontend = frontend
        self.rows = rows
        self.columns = columns
        self.path = path.map { shell.resolve($0) }

        var initial: [String] = []
        if let abs = self.path, shell.vfs.isFile(abs), let text = try? shell.vfs.readString(abs) {
            initial = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if initial.last == "" { initial.removeLast() }
        }
        self.editor = VisualEditor(lines: initial, filename: path)
    }

    /// Draw the current editor screen onto the frontend: home the cursor, clear,
    /// and write each rendered row.
    public func redraw() {
        var out = "\u{1b}[H\u{1b}[2J"
        let screen = editor.render(rows: rows, columns: columns)
        // Join with a bare "\n": the emulator's line feed already returns the
        // cursor to column 0 (ONLCR), and an adjacent "\r\n" would be clustered
        // by Swift into a single Character that the emulator can't interpret.
        out += screen.joined(separator: "\n")
        frontend.write(out)
    }

    /// Feed raw terminal input (keystrokes / escape sequences). Applies every
    /// resulting editor action and redraws once at the end. Returns true while
    /// the session is still open (false once the user has quit).
    @discardableResult
    public func feedInput(_ input: String) -> Bool {
        feedKeys(KeyDecoder.decode(input))
    }

    /// Feed already-decoded key events. This is the path the interactive
    /// ``Session`` uses when it hands control to the editor: it has already
    /// decoded the stream, so re-decoding would be wasteful (and lossy across a
    /// handoff boundary). Applies actions and redraws once at the end.
    @discardableResult
    public func feedKeys(_ keys: [KeyEvent]) -> Bool {
        for key in keys {
            for action in editor.handle(key) {
                switch action {
                case .write(let file):
                    writeBuffer(to: file)
                case .quit:
                    finished = true
                case .bell:
                    break
                }
            }
            if finished { break }
        }
        redraw()
        return !finished
    }

    private func writeBuffer(to file: String?) {
        let target = file.map { shell.resolve($0) } ?? path
        guard let abs = target else { return }
        try? shell.vfs.writeFile(abs, string: editor.text)
    }
}

extension Shell {
    /// Start a full-screen visual editor session for `path` bound to `frontend`.
    /// The host then feeds keystrokes via ``EditorSession/feedInput(_:)``. This
    /// is what an on-device `vi <file>` invocation drives.
    public func makeEditorSession(
        path: String?,
        frontend: TerminalFrontend,
        rows: Int = 24,
        columns: Int = 80
    ) -> EditorSession {
        let session = EditorSession(
            shell: self, path: path, frontend: frontend, rows: rows, columns: columns
        )
        session.redraw()
        return session
    }
}
