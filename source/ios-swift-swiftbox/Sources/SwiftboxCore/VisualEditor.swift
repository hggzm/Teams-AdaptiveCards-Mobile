import Foundation

/// A full-screen, modal `vi`-style editor engine — the visual counterpart to
/// the line-oriented ``EdEditor``.
///
/// Like the rest of the core it does **no I/O**: it owns the text buffer and
/// cursor, consumes decoded ``KeyEvent`` values, and renders a screen snapshot
/// on demand. The host (``EditorSession``) performs the VFS read/write and feeds
/// keystrokes, so the whole modal editing loop is driven identically by a test,
/// a raw stdin, or an on-device terminal view — fully simulated, no device.
public struct VisualEditor {
    public enum Mode: Equatable { case normal, insert, command }

    /// Side effects the host must perform after a keystroke.
    public enum Action: Equatable {
        case write(file: String?)
        case quit
        case bell
    }

    public private(set) var lines: [String]
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0
    public private(set) var mode: Mode = .normal
    public private(set) var commandLine: String = ""
    public private(set) var top: Int = 0          // first buffer row shown
    public private(set) var status: String = ""
    public private(set) var dirty = false
    public var filename: String?

    /// Pending first key of a two-key normal-mode command (`g`).
    private var pending: Character?
    /// Pending operator (`d`/`c`) awaiting a motion (`dw`, `c$`, `dd`, …).
    private var pendingOperator: Character?
    /// Numeric count prefix being accumulated in normal mode (0 = none).
    private var count = 0
    /// Count typed *after* an operator (`d3w`); multiplies the operator count.
    private var operatorCount = 0
    /// Last `/` search pattern and direction, reused by `n`/`N`.
    private var lastSearch = ""
    private var searchForward = true

    public init(lines: [String] = [], filename: String? = nil) {
        self.lines = lines.isEmpty ? [""] : lines
        self.filename = filename
        if let filename { status = "\"\(filename)\" \(self.lines.count)L" }
    }

    // MARK: - Buffer text

    /// The buffer joined back into a single string with a trailing newline
    /// (the on-disk form), or empty for a single empty line.
    public var text: String {
        if lines.count == 1 && lines[0].isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Keystroke handling

    @discardableResult
    public mutating func handle(_ key: KeyEvent) -> [Action] {
        switch mode {
        case .normal: return handleNormal(key)
        case .insert: return handleInsert(key)
        case .command: return handleCommand(key)
        }
    }

    // MARK: Normal mode

    private mutating func handleNormal(_ key: KeyEvent) -> [Action] {
        // An operator (`d`/`c`) is awaiting its motion.
        if let op = pendingOperator { return resolveOperator(op, key) }
        // A two-key prefix (`g`) is awaiting its second key.
        if let first = pending { return resolvePending(first, key) }

        // Accumulate a numeric count prefix. `0` is the home motion unless a
        // count is already in progress (then it's a digit, e.g. `10j`).
        if case .char(let c) = key, c.isNumber, let d = c.wholeNumberValue, (c != "0" || count > 0) {
            count = count * 10 + d
            return []
        }

        // Operators and prefixes keep the pending count for their motion.
        switch key {
        case .char("d"): pendingOperator = "d"; return []
        case .char("c"): pendingOperator = "c"; return []
        case .char("g"): pending = "g"; return []
        default: break
        }

        let n = max(1, count)
        let hadCount = count > 0
        count = 0

        switch key {
        case .char("h"), .left:  for _ in 0..<n { moveLeft() }
        case .char("l"), .right: for _ in 0..<n { moveRight() }
        case .char("k"), .up:    for _ in 0..<n { moveUp() }
        case .char("j"), .down:  for _ in 0..<n { moveDown() }
        case .char("0"), .home:  cursorColumn = 0
        case .char("$"), .end:   cursorColumn = max(0, currentLine.count - 1)
        case .char("w"):         for _ in 0..<n { moveWordForward() }
        case .char("b"):         for _ in 0..<n { moveWordBackward() }
        case .char("G"):         cursorRow = hadCount ? min(n - 1, lines.count - 1) : lines.count - 1; clampColumn()
        case .char("x"):         for _ in 0..<n { deleteCharUnderCursor() }
        case .char("D"):         deleteSpan(from: cursorColumn, to: currentLine.count, change: false)
        case .char("C"):         deleteSpan(from: cursorColumn, to: currentLine.count, change: true)
        case .char("s"):         deleteSpan(from: cursorColumn, to: min(cursorColumn + n, currentLine.count), change: true)
        case .char("i"):         mode = .insert
        case .char("a"):         if !currentLine.isEmpty { cursorColumn += 1 }; mode = .insert
        case .char("I"):         cursorColumn = 0; mode = .insert
        case .char("A"):         cursorColumn = currentLine.count; mode = .insert
        case .char("o"):         openLineBelow()
        case .char("O"):         openLineAbove()
        case .char("/"):         mode = .command; commandLine = "/"
        case .char("n"):         return repeatSearch(forward: searchForward)
        case .char("N"):         return repeatSearch(forward: !searchForward)
        case .char(":"):         mode = .command; commandLine = ":"
        default:                 return [.bell]
        }
        clampColumn()
        scrollToCursor()
        return []
    }

    /// Resolve the second key of a `g`-prefixed command (`gg`, `5gg`).
    private mutating func resolvePending(_ first: Character, _ key: KeyEvent) -> [Action] {
        pending = nil
        let hadCount = count > 0
        let n = max(1, count)
        count = 0
        guard case .char(let c) = key else { return [.bell] }
        switch (first, c) {
        case ("g", "g"):
            cursorRow = hadCount ? min(n - 1, lines.count - 1) : 0
            clampColumn(); scrollToCursor(); return []
        default:
            return [.bell]
        }
    }

    /// Resolve an operator (`d`/`c`) once its motion key arrives: `dw`, `db`,
    /// `d$`, `d0`, `dl`, `dh`, the linewise `dd`/`cc`, and the `c` variants that
    /// then enter insert mode. A count may sit on either side (`2dw`, `d3w`).
    private mutating func resolveOperator(_ op: Character, _ key: KeyEvent) -> [Action] {
        if case .escape = key {
            pendingOperator = nil; count = 0; operatorCount = 0
            return []
        }
        // A count may follow the operator: `d3w`.
        if case .char(let c) = key, c.isNumber, let d = c.wholeNumberValue, (c != "0" || operatorCount > 0) {
            operatorCount = operatorCount * 10 + d
            return []
        }
        let n = max(1, count) * max(1, operatorCount)
        pendingOperator = nil; count = 0; operatorCount = 0

        let chars = Array(currentLine)
        switch key {
        case .char(op):   // `dd` / `cc` — linewise
            if op == "c" { changeLines(n) } else { deleteLines(n) }
        case .char("w"):
            let target = op == "c"
                ? endOfWordColumn(chars, from: cursorColumn, times: n)
                : nextWordColumn(chars, from: cursorColumn, times: n)
            deleteSpan(from: cursorColumn, to: target, change: op == "c")
        case .char("b"):
            let target = prevWordColumn(chars, from: cursorColumn, times: n)
            deleteSpan(from: target, to: cursorColumn, change: op == "c")
        case .char("$"), .end:
            deleteSpan(from: cursorColumn, to: chars.count, change: op == "c")
        case .char("0"), .home:
            deleteSpan(from: 0, to: cursorColumn, change: op == "c")
        case .char("l"), .right:
            deleteSpan(from: cursorColumn, to: min(cursorColumn + n, chars.count), change: op == "c")
        case .char("h"), .left:
            deleteSpan(from: max(cursorColumn - n, 0), to: cursorColumn, change: op == "c")
        default:
            return [.bell]
        }
        scrollToCursor()
        return []
    }

    // MARK: Insert mode

    private mutating func handleInsert(_ key: KeyEvent) -> [Action] {
        switch key {
        case .escape:
            mode = .normal
            if cursorColumn > 0 { cursorColumn -= 1 }
            clampColumn()
        case .enter:
            splitLineAtCursor()
        case .backspace:
            backspace()
        case .char(let c):
            insert(c)
        default:
            return [.bell]
        }
        scrollToCursor()
        return []
    }

    // MARK: Command-line mode (":")

    private mutating func handleCommand(_ key: KeyEvent) -> [Action] {
        switch key {
        case .escape:
            mode = .normal; commandLine = ""
        case .enter:
            let full = commandLine
            mode = .normal
            commandLine = ""
            if full.hasPrefix("/") {
                return performSearch(String(full.dropFirst()), forward: true)
            }
            return execute(String(full.dropFirst()))   // drop leading ':'
        case .backspace:
            if commandLine.count > 1 { commandLine.removeLast() }
            else { mode = .normal; commandLine = "" }
        case .char(let c):
            commandLine.append(c)
        default:
            break
        }
        return []
    }

    /// Execute an ex command typed after `:` — the visual editor supports the
    /// handful that matter for a usable session: `w`, `q`, `q!`, `wq`/`x`, and
    /// `w <file>`.
    private mutating func execute(_ raw: String) -> [Action] {
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        switch cmd {
        case "w":
            status = "written"; dirty = false
            return [.write(file: nil)]
        case "q":
            if dirty { status = "E37: No write since last change (add ! to override)"; return [.bell] }
            return [.quit]
        case "q!":
            return [.quit]
        case "wq", "x":
            dirty = false
            return [.write(file: nil), .quit]
        default:
            if cmd.hasPrefix("w ") {
                let file = String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                status = "\"\(file)\" written"; dirty = false
                return [.write(file: file)]
            }
            status = "E492: Not an editor command: \(cmd)"
            return [.bell]
        }
    }

    // MARK: - Editing primitives

    private var currentLine: String {
        get { lines[cursorRow] }
        set { lines[cursorRow] = newValue }
    }

    private mutating func insert(_ c: Character) {
        var chars = Array(currentLine)
        let idx = min(cursorColumn, chars.count)
        chars.insert(c, at: idx)
        currentLine = String(chars)
        cursorColumn = idx + 1
        dirty = true
    }

    private mutating func splitLineAtCursor() {
        let chars = Array(currentLine)
        let idx = min(cursorColumn, chars.count)
        let head = String(chars[..<idx])
        let tail = String(chars[idx...])
        lines[cursorRow] = head
        lines.insert(tail, at: cursorRow + 1)
        cursorRow += 1
        cursorColumn = 0
        dirty = true
    }

    private mutating func backspace() {
        if cursorColumn > 0 {
            var chars = Array(currentLine)
            chars.remove(at: cursorColumn - 1)
            currentLine = String(chars)
            cursorColumn -= 1
            dirty = true
        } else if cursorRow > 0 {
            // Join with the previous line.
            let prev = lines[cursorRow - 1]
            let joinAt = prev.count
            lines[cursorRow - 1] = prev + currentLine
            lines.remove(at: cursorRow)
            cursorRow -= 1
            cursorColumn = joinAt
            dirty = true
        }
    }

    private mutating func deleteCharUnderCursor() {
        var chars = Array(currentLine)
        guard !chars.isEmpty, cursorColumn < chars.count else { return }
        chars.remove(at: cursorColumn)
        currentLine = String(chars)
        if cursorColumn >= chars.count { cursorColumn = max(0, chars.count - 1) }
        dirty = true
    }

    private mutating func deleteLines(_ count: Int) {
        let end = min(cursorRow + max(1, count), lines.count)
        lines.removeSubrange(cursorRow..<end)
        if lines.isEmpty { lines = [""] }
        if cursorRow >= lines.count { cursorRow = lines.count - 1 }
        cursorColumn = 0
        dirty = true
    }

    /// `cc`: clear `count` lines down to a single empty line and enter insert.
    private mutating func changeLines(_ count: Int) {
        let end = min(cursorRow + max(1, count), lines.count)
        lines.removeSubrange(cursorRow..<end)
        lines.insert("", at: cursorRow)
        cursorColumn = 0
        mode = .insert
        dirty = true
    }

    /// Delete the half-open column span `[lo, hi)` on the current line. When
    /// `change` is set (a `c` operator) the editor then enters insert mode.
    private mutating func deleteSpan(from lo: Int, to hi: Int, change: Bool) {
        var chars = Array(currentLine)
        let a = max(0, min(lo, chars.count))
        let b = max(a, min(hi, chars.count))
        if a < b {
            chars.removeSubrange(a..<b)
            currentLine = String(chars)
            dirty = true
        }
        cursorColumn = a
        if change { mode = .insert } else { clampColumn() }
    }

    // Pure word-boundary column helpers (operate on one line's characters).

    /// Column `count` `w`-motions forward lands on (may equal `chars.count`).
    private func nextWordColumn(_ chars: [Character], from col: Int, times: Int) -> Int {
        var i = col
        for _ in 0..<times {
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }
        return i
    }

    /// End-of-word column (`cw` stops at the word end, not the next word start).
    private func endOfWordColumn(_ chars: [Character], from col: Int, times: Int) -> Int {
        var i = col
        for _ in 0..<times {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
        }
        return i
    }

    /// Column `count` `b`-motions backward lands on.
    private func prevWordColumn(_ chars: [Character], from col: Int, times: Int) -> Int {
        var i = min(col, chars.count)
        for _ in 0..<times {
            i -= 1
            while i > 0, chars[i].isWhitespace { i -= 1 }
            while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
            if i < 0 { i = 0 }
        }
        return max(0, i)
    }

    private mutating func openLineBelow() {
        lines.insert("", at: cursorRow + 1)
        cursorRow += 1
        cursorColumn = 0
        mode = .insert
        dirty = true
    }

    private mutating func openLineAbove() {
        lines.insert("", at: cursorRow)
        cursorColumn = 0
        mode = .insert
        dirty = true
    }

    // MARK: - Motions

    private mutating func moveLeft()  { if cursorColumn > 0 { cursorColumn -= 1 } }
    private mutating func moveRight() { if cursorColumn < max(0, currentLine.count - 1) { cursorColumn += 1 } }
    private mutating func moveUp()    { if cursorRow > 0 { cursorRow -= 1; clampColumn() } }
    private mutating func moveDown()  { if cursorRow < lines.count - 1 { cursorRow += 1; clampColumn() } }

    private mutating func moveWordForward() {
        let chars = Array(currentLine)
        var i = cursorColumn
        // Skip the current run of non-space, then any spaces, to land on the
        // next word's first character.
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i >= chars.count, cursorRow < lines.count - 1 {
            cursorRow += 1; cursorColumn = 0
        } else {
            cursorColumn = min(i, max(0, chars.count - 1))
        }
    }

    private mutating func moveWordBackward() {
        let chars = Array(currentLine)
        var i = min(cursorColumn, chars.count) - 1
        while i > 0, chars[i].isWhitespace { i -= 1 }
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        if i < 0 { i = 0 }
        cursorColumn = max(0, i)
    }

    private mutating func clampColumn() {
        let maxCol = mode == .insert ? currentLine.count : max(0, currentLine.count - 1)
        cursorColumn = min(max(0, cursorColumn), maxCol)
    }

    // MARK: - Search

    private mutating func performSearch(_ pattern: String, forward: Bool) -> [Action] {
        let pat = pattern.isEmpty ? lastSearch : pattern
        guard !pat.isEmpty else { status = "E35: no previous search"; return [.bell] }
        lastSearch = pat
        searchForward = forward
        return findNext(pat, forward: forward)
    }

    private mutating func repeatSearch(forward: Bool) -> [Action] {
        guard !lastSearch.isEmpty else { status = "E35: no previous search"; return [.bell] }
        return findNext(lastSearch, forward: forward)
    }

    /// Literal-substring search across lines from the cursor, wrapping around
    /// the buffer. (Literal for now — a regex `/` is a later step.)
    private mutating func findNext(_ pat: String, forward: Bool) -> [Action] {
        let lineCount = lines.count
        let needle = Array(pat)
        for delta in 0...lineCount {
            let row = forward
                ? (cursorRow + delta) % lineCount
                : ((cursorRow - delta) % lineCount + lineCount) % lineCount
            let chars = Array(lines[row])
            if forward {
                let from = delta == 0 ? cursorColumn + 1 : 0
                if let hit = firstMatch(chars, needle: needle, fromColumn: from) {
                    moveToMatch(row, hit, "/", pat); return []
                }
            } else {
                let before = delta == 0 ? cursorColumn : chars.count + 1
                if let hit = lastMatch(chars, needle: needle, beforeColumn: before) {
                    moveToMatch(row, hit, "?", pat); return []
                }
            }
        }
        status = "E486: pattern not found: \(pat)"
        return [.bell]
    }

    private mutating func moveToMatch(_ row: Int, _ col: Int, _ sigil: String, _ pat: String) {
        cursorRow = row; cursorColumn = col
        clampColumn(); scrollToCursor()
        status = "\(sigil)\(pat)"
    }

    private func firstMatch(_ chars: [Character], needle: [Character], fromColumn: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        var i = max(0, fromColumn)
        while i + needle.count <= chars.count {
            if Array(chars[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    private func lastMatch(_ chars: [Character], needle: [Character], beforeColumn: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        var best: Int?
        var i = 0
        while i + needle.count <= chars.count {
            if i < beforeColumn, Array(chars[i..<i + needle.count]) == needle { best = i }
            i += 1
        }
        return best
    }

    // MARK: - Viewport

    /// Keep the cursor visible within a `viewportRows`-high window. Defaults to
    /// a generous height; ``render(rows:columns:)`` re-scrolls for its own size.
    private mutating func scrollToCursor(viewportRows: Int = 23) {
        if cursorRow < top { top = cursorRow }
        else if cursorRow >= top + viewportRows { top = cursorRow - viewportRows + 1 }
        if top < 0 { top = 0 }
    }

    /// Render the editor onto a `rows`×`columns` screen: the last row is the
    /// status/command line, the rest show buffer lines (with `~` past the end,
    /// classic vi), truncated to `columns`.
    public func render(rows: Int, columns: Int) -> [String] {
        let textRows = max(1, rows - 1)
        var visibleTop = top
        if cursorRow < visibleTop { visibleTop = cursorRow }
        else if cursorRow >= visibleTop + textRows { visibleTop = cursorRow - textRows + 1 }
        if visibleTop < 0 { visibleTop = 0 }

        var screen: [String] = []
        for r in 0..<textRows {
            let idx = visibleTop + r
            if idx < lines.count {
                screen.append(String(lines[idx].prefix(columns)))
            } else {
                screen.append("~")
            }
        }
        let bottom: String
        if mode == .command { bottom = String(commandLine.prefix(columns)) }
        else {
            let modeTag = mode == .insert ? "-- INSERT --" : ""
            let pos = "\(cursorRow + 1),\(cursorColumn + 1)"
            let left = modeTag.isEmpty ? status : modeTag
            let pad = max(1, columns - left.count - pos.count)
            bottom = String((left + String(repeating: " ", count: pad) + pos).prefix(columns))
        }
        screen.append(bottom)
        return screen
    }
}
