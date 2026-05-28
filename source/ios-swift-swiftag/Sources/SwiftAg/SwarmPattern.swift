import Foundation

/// Speaker selection driven by explicit `HANDOFF: <name>` markers
/// embedded in the last assistant message. The pattern lets a single
/// agent keep speaking until it explicitly hands off — modelling
/// AG2's swarm: each agent owns the turn until it transfers to a peer.
///
/// Selection rules, in order:
///   1. If the last message contains `HANDOFF: <name>` (case
///      insensitive on `<name>`), select that agent.
///   2. Otherwise re-select the agent named by the last message's
///      `name` field, if it matches a known agent.
///   3. Otherwise fall back to `initialSpeaker` (or `agents.first` if
///      none).
public actor SwarmPattern: GroupChatPattern {
    private let initialSpeaker: String?

    public init(initialSpeaker: String? = nil) {
        self.initialSpeaker = initialSpeaker
    }

    public func selectNext(agents: [Agent], history: [ChatMessage]) -> Agent? {
        guard !agents.isEmpty else { return nil }

        if let last = history.last {
            if let target = SwarmPattern.parseHandoff(from: last.content),
               let match = agents.first(where: { $0.identity.name.lowercased() == target.lowercased() }) {
                return match
            }
            if let name = last.name,
               let match = agents.first(where: { $0.identity.name == name }) {
                return match
            }
        }

        if let initial = initialSpeaker,
           let match = agents.first(where: { $0.identity.name == initial }) {
            return match
        }
        return agents.first
    }

    /// Extracts `<name>` from the first `HANDOFF: <name>` occurrence
    /// in `text`. Returns `nil` if absent. Public so callers can
    /// reason about transcripts without re-importing the rule.
    public static func parseHandoff(from text: String) -> String? {
        let upper = text.uppercased()
        guard let range = upper.range(of: "HANDOFF:") else { return nil }
        // Map the upper-case match back to the original string for
        // the captured name to preserve casing in error messages.
        let tailUpperStart = range.upperBound
        let offset = upper.distance(from: upper.startIndex, to: tailUpperStart)
        let originalStart = text.index(text.startIndex, offsetBy: offset)
        let tail = text[originalStart...]
        let trimmed = tail.drop(while: { $0 == " " || $0 == "\t" })
        let nameRun = trimmed.prefix(while: { ch in
            ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
        })
        return nameRun.isEmpty ? nil : String(nameRun)
    }
}
