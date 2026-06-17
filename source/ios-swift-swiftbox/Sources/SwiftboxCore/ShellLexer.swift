import Foundation

/// Operator-aware scanner for a shell line.
///
/// ``ShellParser`` splits a single command into words; ``ShellLexer`` works one
/// level up, slicing a full line into *segments* of literal text and the shell
/// *operators* between them (`;`, `&&`, `||`, `|`, `>>`, `>`) while honoring
/// single quotes, double quotes and backslash escapes. The ``Shell`` then
/// interprets the resulting token stream as statements, and/or lists, pipelines
/// and redirections.
public enum ShellLexer {
    public struct Token: Equatable {
        public enum Kind: Equatable { case segment, op }
        public var kind: Kind
        public var text: String

        public var isOperator: Bool { kind == .op }
        public var isRedirection: Bool { kind == .op && (text == ">" || text == ">>") }
    }

    /// Operators in longest-match-first order so `&&` beats `&`, `||` beats `|`
    /// and `>>` beats `>`.
    private static let operators = ["&&", "||", ">>", ";", "|", ">"]

    public static func scan(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        let chars = Array(line)
        var i = 0

        func flushSegment() {
            if !current.isEmpty {
                tokens.append(Token(kind: .segment, text: current))
                current = ""
            }
        }

        while i < chars.count {
            let ch = chars[i]

            if escaped {
                current.append(ch)
                escaped = false
                i += 1
                continue
            }
            if ch == "\\" && !inSingle {
                current.append(ch)
                escaped = true
                i += 1
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                current.append(ch)
                i += 1
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                current.append(ch)
                i += 1
                continue
            }

            if !inSingle && !inDouble {
                if let op = matchOperator(chars, at: i) {
                    flushSegment()
                    tokens.append(Token(kind: .op, text: op))
                    i += op.count
                    continue
                }
            }

            current.append(ch)
            i += 1
        }
        flushSegment()
        return tokens
    }

    private static func matchOperator(_ chars: [Character], at index: Int) -> String? {
        for op in operators {
            let opChars = Array(op)
            guard index + opChars.count <= chars.count else { continue }
            if Array(chars[index..<(index + opChars.count)]) == opChars { return op }
        }
        return nil
    }

    /// Split a token stream on a given operator into sub-streams (operator
    /// dropped). Trailing/leading empties are preserved by the caller's filter.
    public static func split(_ tokens: [Token], on op: String) -> [[Token]] {
        var groups: [[Token]] = []
        var current: [Token] = []
        for token in tokens {
            if token.isOperator && token.text == op {
                groups.append(current)
                current = []
            } else {
                current.append(token)
            }
        }
        groups.append(current)
        return groups
    }

    /// A pipeline plus the connector (`&&` / `||`) that preceded it.
    public struct AndOrGroup: Equatable {
        public var connector: String?   // nil for the first group
        public var tokens: [Token]
    }

    /// Split a statement into and/or groups, recording each group's preceding
    /// connector for short-circuit evaluation.
    public static func splitAndOr(_ tokens: [Token]) -> [AndOrGroup] {
        var groups: [AndOrGroup] = []
        var current: [Token] = []
        var pendingConnector: String?
        for token in tokens {
            if token.isOperator && (token.text == "&&" || token.text == "||") {
                groups.append(AndOrGroup(connector: pendingConnector, tokens: current))
                current = []
                pendingConnector = token.text
            } else {
                current.append(token)
            }
        }
        groups.append(AndOrGroup(connector: pendingConnector, tokens: current))
        return groups
    }
}
