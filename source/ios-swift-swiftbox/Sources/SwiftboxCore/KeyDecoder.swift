import Foundation

/// A decoded keyboard event from a raw terminal input stream.
///
/// A real terminal delivers keystrokes as bytes: printable characters directly,
/// and special keys as ANSI escape sequences (e.g. `ESC [ A` for Up). A UI like
/// SwiftTerm hands its `TerminalViewDelegate` exactly such a byte stream, so
/// decoding it here means the interactive ``LineEditor``/``Session`` are driven
/// identically by a test, a raw stdin, or an on-device terminal view.
public enum KeyEvent: Equatable {
    case char(Character)
    case enter
    case backspace
    case delete
    case tab
    case left
    case right
    case up
    case down
    case home
    case end
    /// A recognized Ctrl-<letter> chord (letter is lowercased, e.g. `a` for Ctrl-A).
    case control(Character)
    /// A bare ESC with no following recognizable sequence.
    case escape
}

/// Decodes a raw input string into ``KeyEvent`` values, recognizing the common
/// xterm escape sequences for arrows, Home/End and Delete.
public enum KeyDecoder {
    public static func decode(_ input: String) -> [KeyEvent] {
        var events: [KeyEvent] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\r", "\n", "\r\n":
                // Swift clusters an adjacent CR+LF into a single grapheme, so a
                // CRLF arrives here as one Character — still one Enter.
                events.append(.enter)
            case "\u{7f}", "\u{08}":
                events.append(.backspace)
            case "\t":
                events.append(.tab)
            case "\u{1b}":
                let (event, consumed) = decodeEscape(chars, from: i)
                events.append(event)
                i += consumed - 1
            default:
                let scalar = c.unicodeScalars.first?.value ?? 0
                if scalar < 0x20, let letter = controlLetter(for: scalar) {
                    events.append(.control(letter))
                } else {
                    events.append(.char(c))
                }
            }
            i += 1
        }
        return events
    }

    /// Decode an escape sequence starting at `start` (which is the ESC).
    /// Returns the event and the number of characters consumed (>= 1).
    private static func decodeEscape(_ chars: [Character], from start: Int) -> (KeyEvent, Int) {
        // Need at least ESC [ X.
        guard start + 1 < chars.count else { return (.escape, 1) }
        guard chars[start + 1] == "[" || chars[start + 1] == "O" else { return (.escape, 1) }
        guard start + 2 < chars.count else { return (.escape, 2) }

        switch chars[start + 2] {
        case "A": return (.up, 3)
        case "B": return (.down, 3)
        case "C": return (.right, 3)
        case "D": return (.left, 3)
        case "H": return (.home, 3)
        case "F": return (.end, 3)
        case "1":
            // ESC [ 1 ~  = Home, ESC [ 3 ~ = Delete, etc.
            if start + 3 < chars.count, chars[start + 3] == "~" { return (.home, 4) }
            return (.escape, 3)
        case "3":
            if start + 3 < chars.count, chars[start + 3] == "~" { return (.delete, 4) }
            return (.escape, 3)
        case "4":
            if start + 3 < chars.count, chars[start + 3] == "~" { return (.end, 4) }
            return (.escape, 3)
        default:
            return (.escape, 2)
        }
    }

    private static func controlLetter(for scalar: UInt32) -> Character? {
        // Ctrl-A = 1 ... Ctrl-Z = 26.
        guard scalar >= 1, scalar <= 26 else { return nil }
        let letter = Character(Unicode.Scalar(scalar - 1 + UInt32(UnicodeScalar("a").value))!)
        return letter
    }
}
