import Foundation

extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}

/// A minimal ANSI/VT terminal emulator: a fixed grid plus a cursor, fed a byte
/// stream and a handful of CSI escape sequences. This mirrors the role of
/// Termux's `terminal-emulator` module — the SwiftUI terminal view (Apple-only)
/// will render the grid this class maintains.
public final class TerminalEmulator {
    public let rows: Int
    public let columns: Int
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0

    private var grid: [[Character]]
    private var escapeBuffer: String = ""
    private var inEscape = false

    public init(rows: Int = 24, columns: Int = 80) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.grid = Array(
            repeating: Array(repeating: " ", count: self.columns),
            count: self.rows
        )
    }

    public func feed(_ text: String) {
        for ch in text { feed(ch) }
    }

    private func feed(_ ch: Character) {
        if inEscape {
            appendEscape(ch)
            return
        }
        switch ch {
        case "\u{1b}":
            inEscape = true
            escapeBuffer = ""
        case "\n":
            lineFeed()
        case "\r":
            cursorColumn = 0
        case "\u{8}":
            if cursorColumn > 0 { cursorColumn -= 1 }
        case "\t":
            cursorColumn = min(((cursorColumn / 8) + 1) * 8, columns - 1)
        default:
            putChar(ch)
        }
    }

    private func appendEscape(_ ch: Character) {
        escapeBuffer.append(ch)
        // Only CSI sequences (ESC [ ... finalByte) are understood; anything
        // else is silently dropped so unsupported sequences cannot corrupt
        // the grid.
        if escapeBuffer.count == 1 {
            if ch != "[" {
                inEscape = false
                escapeBuffer = ""
            }
            return
        }
        if let scalar = ch.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
            handleCSI(escapeBuffer)
            inEscape = false
            escapeBuffer = ""
        }
    }

    private func handleCSI(_ seq: String) {
        let body = seq.dropFirst() // drop "["
        guard let final = body.last else { return }
        let params = body.dropLast().split(separator: ";").map { Int($0) ?? 0 }
        func p(_ i: Int, _ def: Int) -> Int { i < params.count ? params[i] : def }
        switch final {
        case "H", "f":
            cursorRow = clampRow((p(0, 1)) - 1)
            cursorColumn = clampCol((p(1, 1)) - 1)
        case "J":
            if p(0, 0) == 2 { clear() }
        case "K":
            for c in cursorColumn..<columns { grid[cursorRow][c] = " " }
        case "A":
            cursorRow = clampRow(cursorRow - max(1, p(0, 1)))
        case "B":
            cursorRow = clampRow(cursorRow + max(1, p(0, 1)))
        case "C":
            cursorColumn = clampCol(cursorColumn + max(1, p(0, 1)))
        case "D":
            cursorColumn = clampCol(cursorColumn - max(1, p(0, 1)))
        default:
            break
        }
    }

    private func clampRow(_ r: Int) -> Int { min(max(0, r), rows - 1) }
    private func clampCol(_ c: Int) -> Int { min(max(0, c), columns - 1) }

    private func putChar(_ ch: Character) {
        if cursorColumn >= columns {
            cursorColumn = 0
            lineFeed()
        }
        grid[cursorRow][cursorColumn] = ch
        cursorColumn += 1
    }

    private func lineFeed() {
        // No tty line discipline sits in front of this emulator, so a line feed
        // also returns the cursor to column 0 (as ONLCR would map \n -> \r\n).
        cursorColumn = 0
        if cursorRow == rows - 1 {
            grid.removeFirst()
            grid.append(Array(repeating: " ", count: columns))
        } else {
            cursorRow += 1
        }
    }

    public func clear() {
        grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        cursorRow = 0
        cursorColumn = 0
    }

    public func line(_ row: Int) -> String {
        guard row >= 0 && row < rows else { return "" }
        return String(grid[row]).trimmingTrailingSpaces()
    }

    /// All non-empty trailing whitespace trimmed; rows joined by newlines.
    public func snapshot() -> String {
        grid.map { String($0).trimmingTrailingSpaces() }
            .joined(separator: "\n")
            .trimmingTrailingNewlines()
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}
