import Foundation

/// A faithful-enough implementation of the classic Unix line editor `ed` — the
/// original 1969 editor and the line/ex mode that lives behind `ex`/`vi`.
///
/// It is a pure value type with **no I/O**: it holds the buffer, applies a
/// newline-separated command script, and reports the produced output plus any
/// requested writes. The host (a shell builtin) performs the actual VFS reads
/// and writes. That keeps the genuine `ed` command lineage fully simulated —
/// no device, no native toolchain — and trivially unit-testable.
///
/// Supported address forms: `N`, `.` (current line), `$` (last line), `+`/`-`
/// with optional counts, `A,B` ranges, and a leading `,` / `;` meaning the
/// whole file. Supported commands: `p` (print), `n` (numbered print), `=`
/// (line number), `a`/`i`/`c` (append/insert/change, input ended by a lone
/// `.`), `d` (delete), `s/re/repl/[g]` (substitute), `w [file]` (write),
/// `q` (quit), and `wq`/`x` (write then quit). A bare address sets and prints
/// the current line; an empty command advances and prints the next line.
public struct EdEditor {
    public private(set) var lines: [String]
    /// Current line ("dot"), 1-based. `0` denotes an empty buffer / position
    /// before the first line.
    public private(set) var dot: Int
    public var defaultFilename: String?

    public init(lines: [String] = [], filename: String? = nil) {
        self.lines = lines
        self.defaultFilename = filename
        self.dot = lines.count
    }

    /// A requested write of the current buffer to `file` (or the default file
    /// when `file` is nil).
    public struct Write: Equatable {
        public let file: String?
        public let contents: String
    }

    public struct Result {
        public var output = ""
        public var writes: [Write] = []
        public var hadError = false
        public var quit = false
    }

    // MARK: - Command interpreter

    public mutating func run(_ script: String) -> Result {
        var result = Result()
        var cmds = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if cmds.last == "" { cmds.removeLast() }   // forgive a trailing newline

        var i = 0
        while i < cmds.count {
            if result.quit { break }
            let chars = Array(cmds[i])
            i += 1
            var p = 0

            // ---- addresses ----
            func parseAddr() -> Int? {
                guard p < chars.count else { return nil }
                var base: Int?
                switch chars[p] {
                case ".": base = dot; p += 1
                case "$": base = lines.count; p += 1
                case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    var n = 0
                    while p < chars.count, chars[p].isNumber, let d = chars[p].wholeNumberValue {
                        n = n * 10 + d; p += 1
                    }
                    base = n
                case "+", "-":
                    base = dot
                default:
                    base = nil
                }
                while p < chars.count, chars[p] == "+" || chars[p] == "-" {
                    let sign = chars[p] == "+" ? 1 : -1; p += 1
                    var n = 0; var got = false
                    while p < chars.count, chars[p].isNumber, let d = chars[p].wholeNumberValue {
                        n = n * 10 + d; p += 1; got = true
                    }
                    base = (base ?? dot) + sign * (got ? n : 1)
                }
                return base
            }

            var start = parseAddr()
            var end: Int?
            if p < chars.count, chars[p] == "," || chars[p] == ";" {
                let whole = chars[p] == ","
                p += 1
                let a2 = parseAddr()
                if start == nil { start = whole ? 1 : dot }
                end = a2 ?? lines.count
            }

            let rest = String(chars[p...]).trimmingCharacters(in: .whitespaces)

            // ---- dispatch ----
            func fail() { result.output += "?\n"; result.hadError = true }
            func clampLine(_ n: Int) -> Int { max(1, min(n, max(lines.count, 1))) }
            func resolvedRange() -> (Int, Int) {
                let s = start ?? dot
                let e = end ?? s
                return (s, e)
            }
            func insert(at index0: Int, _ newLines: [String]) {
                let idx = max(0, min(index0, lines.count))
                lines.insert(contentsOf: newLines, at: idx)
                dot = idx + newLines.count
            }
            func collectInput() -> [String] {
                var input: [String] = []
                while i < cmds.count, cmds[i] != "." { input.append(cmds[i]); i += 1 }
                if i < cmds.count { i += 1 }   // consume the terminating "."
                return input
            }

            // write+quit shorthands
            if rest == "wq" || rest == "x" || rest == "xq" {
                let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
                if defaultFilename == nil { fail() } else {
                    result.writes.append(Write(file: nil, contents: contents))
                    result.quit = true
                }
                continue
            }

            if rest.isEmpty {
                if let s = start {
                    dot = clampLine(s)
                    if !lines.isEmpty { result.output += lines[dot - 1] + "\n" }
                } else {
                    dot = clampLine(dot + 1)
                    if !lines.isEmpty { result.output += lines[dot - 1] + "\n" }
                }
                continue
            }

            let cmd = rest.first!
            let arg = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)

            switch cmd {
            case "p", "n":
                let (s, e) = resolvedRange()
                guard s >= 1, e <= lines.count, s <= e else { fail(); break }
                for ln in s...e {
                    if cmd == "n" { result.output += "\(ln)\t\(lines[ln - 1])\n" }
                    else { result.output += lines[ln - 1] + "\n" }
                }
                dot = e

            case "=":
                let n = end ?? start ?? lines.count
                result.output += "\(n)\n"

            case "d":
                let (s, e) = resolvedRange()
                guard s >= 1, e <= lines.count, s <= e else { fail(); break }
                lines.removeSubrange((s - 1)...(e - 1))
                dot = min(s, lines.count)

            case "a":
                let pos = start ?? dot
                insert(at: pos, collectInput())

            case "i":
                let pos = start ?? dot
                insert(at: max(0, pos - 1), collectInput())

            case "c":
                let (s, e) = resolvedRange()
                let input = collectInput()
                if s >= 1, e <= lines.count, s <= e {
                    lines.removeSubrange((s - 1)...(e - 1))
                }
                insert(at: max(0, (start ?? dot) - 1), input)

            case "s":
                guard let sub = Shell.parseSedSubstitution(rest) else { fail(); break }
                let (s, e) = resolvedRange()
                guard s >= 1, e <= lines.count, s <= e else { fail(); break }
                var any = false
                for idx in (s - 1)...(e - 1) {
                    let (newLine, changed) = EdEditor.substitute(lines[idx], sub)
                    if changed { lines[idx] = newLine; any = true; dot = idx + 1 }
                }
                if !any { fail() }

            case "w":
                let file = arg.isEmpty ? nil : arg
                if file == nil && defaultFilename == nil { fail(); break }
                if let f = file { defaultFilename = f }
                let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
                result.writes.append(Write(file: file, contents: contents))

            case "q":
                result.quit = true

            default:
                fail()
            }
        }
        return result
    }

    // MARK: - Substitution

    /// Apply one `s///` substitution to a line. Honors the global flag; the
    /// pattern is a regular expression and the replacement is literal (no
    /// back-references — adequate for the simulated editor and portable across
    /// platforms via Foundation's regex option).
    static func substitute(_ line: String, _ sub: (pattern: String, replacement: String, global: Bool)) -> (String, Bool) {
        if sub.global {
            let replaced = line.replacingOccurrences(
                of: sub.pattern, with: sub.replacement, options: .regularExpression
            )
            return (replaced, replaced != line)
        }
        guard let r = line.range(of: sub.pattern, options: .regularExpression) else {
            return (line, false)
        }
        return (line.replacingCharacters(in: r, with: sub.replacement), true)
    }
}
