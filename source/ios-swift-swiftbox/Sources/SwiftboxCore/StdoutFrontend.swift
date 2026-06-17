import Foundation

/// A ``TerminalFrontend`` that writes rendered output to a host file handle
/// (stdout by default). This is the desktop/host counterpart to the on-device
/// terminal view: the *same* ``Session`` drives either one, so the sandbox
/// behaves identically whether it runs inside the iOS app or in a Windows /
/// Linux / macOS console. Pure Foundation, no Apple-only types.
public final class StdoutFrontend: TerminalFrontend {
    private let handle: FileHandle
    /// When false, ANSI/VT control sequences are stripped before writing — handy
    /// for dumb pipes / logs where escapes would be noise.
    public let passThroughANSI: Bool

    public init(handle: FileHandle = .standardOutput, passThroughANSI: Bool = true) {
        self.handle = handle
        self.passThroughANSI = passThroughANSI
    }

    public func write(_ text: String) {
        let out = passThroughANSI ? text : StdoutFrontend.stripANSI(text)
        if let data = out.data(using: .utf8) { handle.write(data) }
    }

    public func clearScreen() {
        if passThroughANSI { write("\u{1b}[2J\u{1b}[H") }
    }

    /// Remove CSI escape sequences (`ESC [ … finalByte`) from `text`.
    static func stripANSI(_ text: String) -> String {
        var out = ""
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1b}", i + 1 < chars.count, chars[i + 1] == "[" {
                i += 2
                while i < chars.count, !(0x40...0x7e).contains(chars[i].asciiValue ?? 0) { i += 1 }
                if i < chars.count { i += 1 } // consume the final byte
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }
}
