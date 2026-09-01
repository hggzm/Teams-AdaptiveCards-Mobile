// SwiftHarnessCore — Structured runtime event stream
//
// `RuntimeEvent` is the discriminated union of every event that the
// harness emits during a turn. The runtime exposes these as an
// `AsyncStream<RuntimeEvent>` so callers can render progress, drive
// tests, or persist a trace without coupling to the runtime internals.
//
// JSON wire shape: externally-tagged enum, matching Rust serde's
// default. A unit-less variant such as `.sessionStarted(sessionId:)`
// encodes as `{"SessionStarted": {"session_id": "<uuid>"}}`; every
// variant in this enum carries fields, so every encoded form is the
// outer one-key map. Field names inside the inner object are
// snake_case to match the upstream wire format.

import Foundation

/// Structured event emitted by the swiftharness runtime during a turn.
public enum RuntimeEvent: Equatable, Sendable {
    case sessionStarted(sessionId: SessionId)
    case sessionResumed(sessionId: SessionId, turnIndex: TurnIndex)
    case promptReceived(prompt: Prompt)
    case routeComputed(matchCount: Int)
    case commandMatched(name: CommandName, score: MatchScore)
    case toolMatched(name: ToolName, score: MatchScore)
    case permissionDenied(subject: String, reason: String)
    case commandInvoked(name: CommandName)
    case commandCompleted(name: CommandName, handled: Bool)
    case toolInvoked(name: ToolName)
    case toolCompleted(name: ToolName, handled: Bool)
    case turnCompleted(stopReason: String)
    case sessionPersisted(path: String)
    case transcriptPersisted(path: String)
}

extension RuntimeEvent: Codable {
    // Variant tag keys; the spelling here is the wire tag, so each
    // must match the upstream Rust enum variant identifier exactly.
    private enum Tag: String, CodingKey {
        case SessionStarted
        case SessionResumed
        case PromptReceived
        case RouteComputed
        case CommandMatched
        case ToolMatched
        case PermissionDenied
        case CommandInvoked
        case CommandCompleted
        case ToolInvoked
        case ToolCompleted
        case TurnCompleted
        case SessionPersisted
        case TranscriptPersisted
    }

    // Inner payload structs. Each one mirrors a Rust struct variant's
    // fields with `snake_case` JSON names. Property names use
    // snake_case directly so the Codable synthesizer maps them
    // verbatim — these structs never leave the file so the
    // non-idiomatic spelling is a localized concession.
    private struct SessionStartedPayload: Codable {
        let session_id: SessionId
    }
    private struct SessionResumedPayload: Codable {
        let session_id: SessionId
        let turn_index: TurnIndex
    }
    private struct PromptReceivedPayload: Codable {
        let prompt: Prompt
    }
    private struct RouteComputedPayload: Codable {
        let match_count: Int
    }
    private struct CommandMatchedPayload: Codable {
        let name: CommandName
        let score: MatchScore
    }
    private struct ToolMatchedPayload: Codable {
        let name: ToolName
        let score: MatchScore
    }
    private struct PermissionDeniedPayload: Codable {
        let subject: String
        let reason: String
    }
    private struct CommandNameOnlyPayload: Codable {
        let name: CommandName
    }
    private struct CommandCompletedPayload: Codable {
        let name: CommandName
        let handled: Bool
    }
    private struct ToolNameOnlyPayload: Codable {
        let name: ToolName
    }
    private struct ToolCompletedPayload: Codable {
        let name: ToolName
        let handled: Bool
    }
    private struct TurnCompletedPayload: Codable {
        let stop_reason: String
    }
    private struct PathPayload: Codable {
        let path: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        let keys = container.allKeys
        guard keys.count == 1, let tag = keys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "RuntimeEvent must be a single-key tag object"
            ))
        }
        switch tag {
        case .SessionStarted:
            let p = try container.decode(SessionStartedPayload.self, forKey: tag)
            self = .sessionStarted(sessionId: p.session_id)
        case .SessionResumed:
            let p = try container.decode(SessionResumedPayload.self, forKey: tag)
            self = .sessionResumed(sessionId: p.session_id, turnIndex: p.turn_index)
        case .PromptReceived:
            let p = try container.decode(PromptReceivedPayload.self, forKey: tag)
            self = .promptReceived(prompt: p.prompt)
        case .RouteComputed:
            let p = try container.decode(RouteComputedPayload.self, forKey: tag)
            self = .routeComputed(matchCount: p.match_count)
        case .CommandMatched:
            let p = try container.decode(CommandMatchedPayload.self, forKey: tag)
            self = .commandMatched(name: p.name, score: p.score)
        case .ToolMatched:
            let p = try container.decode(ToolMatchedPayload.self, forKey: tag)
            self = .toolMatched(name: p.name, score: p.score)
        case .PermissionDenied:
            let p = try container.decode(PermissionDeniedPayload.self, forKey: tag)
            self = .permissionDenied(subject: p.subject, reason: p.reason)
        case .CommandInvoked:
            let p = try container.decode(CommandNameOnlyPayload.self, forKey: tag)
            self = .commandInvoked(name: p.name)
        case .CommandCompleted:
            let p = try container.decode(CommandCompletedPayload.self, forKey: tag)
            self = .commandCompleted(name: p.name, handled: p.handled)
        case .ToolInvoked:
            let p = try container.decode(ToolNameOnlyPayload.self, forKey: tag)
            self = .toolInvoked(name: p.name)
        case .ToolCompleted:
            let p = try container.decode(ToolCompletedPayload.self, forKey: tag)
            self = .toolCompleted(name: p.name, handled: p.handled)
        case .TurnCompleted:
            let p = try container.decode(TurnCompletedPayload.self, forKey: tag)
            self = .turnCompleted(stopReason: p.stop_reason)
        case .SessionPersisted:
            let p = try container.decode(PathPayload.self, forKey: tag)
            self = .sessionPersisted(path: p.path)
        case .TranscriptPersisted:
            let p = try container.decode(PathPayload.self, forKey: tag)
            self = .transcriptPersisted(path: p.path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case .sessionStarted(let sid):
            try container.encode(SessionStartedPayload(session_id: sid),
                                 forKey: .SessionStarted)
        case .sessionResumed(let sid, let idx):
            try container.encode(SessionResumedPayload(session_id: sid, turn_index: idx),
                                 forKey: .SessionResumed)
        case .promptReceived(let p):
            try container.encode(PromptReceivedPayload(prompt: p),
                                 forKey: .PromptReceived)
        case .routeComputed(let count):
            try container.encode(RouteComputedPayload(match_count: count),
                                 forKey: .RouteComputed)
        case .commandMatched(let name, let score):
            try container.encode(CommandMatchedPayload(name: name, score: score),
                                 forKey: .CommandMatched)
        case .toolMatched(let name, let score):
            try container.encode(ToolMatchedPayload(name: name, score: score),
                                 forKey: .ToolMatched)
        case .permissionDenied(let subject, let reason):
            try container.encode(PermissionDeniedPayload(subject: subject, reason: reason),
                                 forKey: .PermissionDenied)
        case .commandInvoked(let name):
            try container.encode(CommandNameOnlyPayload(name: name),
                                 forKey: .CommandInvoked)
        case .commandCompleted(let name, let handled):
            try container.encode(CommandCompletedPayload(name: name, handled: handled),
                                 forKey: .CommandCompleted)
        case .toolInvoked(let name):
            try container.encode(ToolNameOnlyPayload(name: name),
                                 forKey: .ToolInvoked)
        case .toolCompleted(let name, let handled):
            try container.encode(ToolCompletedPayload(name: name, handled: handled),
                                 forKey: .ToolCompleted)
        case .turnCompleted(let reason):
            try container.encode(TurnCompletedPayload(stop_reason: reason),
                                 forKey: .TurnCompleted)
        case .sessionPersisted(let path):
            try container.encode(PathPayload(path: path),
                                 forKey: .SessionPersisted)
        case .transcriptPersisted(let path):
            try container.encode(PathPayload(path: path),
                                 forKey: .TranscriptPersisted)
        }
    }
}
