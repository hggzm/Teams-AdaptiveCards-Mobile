import Foundation

/// An interactive single-line editor: a text buffer with a cursor, driven by
/// ``KeyEvent`` values and backed by a command history for up/down recall.
///
/// This is the readline-lite layer between raw keystrokes and the ``Shell``:
/// pressing keys mutates the buffer, Enter submits it. It is pure Swift with no
/// rendering of its own — the ``Session`` reads ``buffer``/``cursor`` after each
/// key and repaints the input line on its ``TerminalFrontend`` — so it is fully
/// testable headlessly and works behind any UI, including SwiftTerm later.
public final class LineEditor {
    public private(set) var buffer: String = ""
    public private(set) var cursor: Int = 0   // index into buffer (0...count)

    /// Snapshot of history at edit time, navigated by up/down.
    private var history: [String]
    private var historyIndex: Int   // == history.count means "current line"
    private var savedLine: String = ""

    public init(history: [String] = []) {
        self.history = history
        self.historyIndex = history.count
    }

    /// The result of feeding a key.
    public enum Outcome: Equatable {
        case updated          // buffer/cursor changed; repaint the line
        case submit(String)   // Enter pressed; line is final
        case ignored          // nothing relevant happened
    }

    /// Replace the history used for up/down navigation (e.g. after a command
    /// was run), resetting navigation to the current line.
    public func setHistory(_ entries: [String]) {
        history = entries
        historyIndex = entries.count
    }

    public func reset() {
        buffer = ""
        cursor = 0
        historyIndex = history.count
        savedLine = ""
    }

    @discardableResult
    public func feed(_ key: KeyEvent) -> Outcome {
        switch key {
        case .char(let c):
            insert(String(c)); return .updated
        case .enter:
            let line = buffer; return .submit(line)
        case .backspace:
            return deleteBackward()
        case .delete:
            return deleteForward()
        case .left:
            if cursor > 0 { cursor -= 1; return .updated }; return .ignored
        case .right:
            if cursor < buffer.count { cursor += 1; return .updated }; return .ignored
        case .home, .control("a"):
            if cursor != 0 { cursor = 0; return .updated }; return .ignored
        case .end, .control("e"):
            if cursor != buffer.count { cursor = buffer.count; return .updated }; return .ignored
        case .control("k"):
            return killToEnd()
        case .control("u"):
            return killToStart()
        case .control("w"):
            return killWordBackward()
        case .up, .control("p"):
            return historyPrev()
        case .down, .control("n"):
            return historyNext()
        case .tab, .escape, .control:
            return .ignored
        }
    }

    /// Feed a batch of decoded keys; returns the last submitted line if any.
    @discardableResult
    public func feed(_ keys: [KeyEvent]) -> String? {
        var submitted: String?
        for key in keys {
            if case .submit(let line) = feed(key) { submitted = line }
        }
        return submitted
    }

    // MARK: Editing

    private func insert(_ text: String) {
        let idx = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.insert(contentsOf: text, at: idx)
        cursor += text.count
    }

    private func deleteBackward() -> Outcome {
        guard cursor > 0 else { return .ignored }
        let idx = buffer.index(buffer.startIndex, offsetBy: cursor - 1)
        buffer.remove(at: idx)
        cursor -= 1
        return .updated
    }

    private func deleteForward() -> Outcome {
        guard cursor < buffer.count else { return .ignored }
        let idx = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.remove(at: idx)
        return .updated
    }

    private func killToEnd() -> Outcome {
        guard cursor < buffer.count else { return .ignored }
        let idx = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.removeSubrange(idx...)
        return .updated
    }

    private func killToStart() -> Outcome {
        guard cursor > 0 else { return .ignored }
        let idx = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.removeSubrange(buffer.startIndex..<idx)
        cursor = 0
        return .updated
    }

    private func killWordBackward() -> Outcome {
        guard cursor > 0 else { return .ignored }
        var start = cursor
        let chars = Array(buffer)
        while start > 0 && chars[start - 1] == " " { start -= 1 }
        while start > 0 && chars[start - 1] != " " { start -= 1 }
        let from = buffer.index(buffer.startIndex, offsetBy: start)
        let to = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.removeSubrange(from..<to)
        cursor = start
        return .updated
    }

    // MARK: History

    private func historyPrev() -> Outcome {
        guard historyIndex > 0 else { return .ignored }
        if historyIndex == history.count { savedLine = buffer }
        historyIndex -= 1
        buffer = history[historyIndex]
        cursor = buffer.count
        return .updated
    }

    private func historyNext() -> Outcome {
        guard historyIndex < history.count else { return .ignored }
        historyIndex += 1
        buffer = historyIndex == history.count ? savedLine : history[historyIndex]
        cursor = buffer.count
        return .updated
    }
}
