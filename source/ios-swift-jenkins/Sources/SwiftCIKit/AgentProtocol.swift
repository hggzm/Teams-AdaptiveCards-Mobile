import Foundation

/// JSON wire protocol between the swiftci controller and a standalone
/// `swiftci-agent`. Both sides exchange Codable `AgentMessage` values
/// as UTF-8 text frames over a single WebSocket connection at
/// `WS /agents`.
///
/// Protocol shape (`type` discriminator + nested payload, like GitHub
/// Actions runner events):
///
///   Agent -> Controller:
///     {"type":"register","payload":{...}}
///     {"type":"log","payload":{...}}
///     {"type":"buildFinished","payload":{...}}
///
///   Controller -> Agent:
///     {"type":"runBuild","payload":{...}}
///     {"type":"cancelBuild","payload":{...}}
///
/// The same `Codable`-derived encoder is used on both sides so the
/// wire format stays in lockstep with the Swift types.
public enum AgentMessage: Codable, Sendable, Equatable {
    /// First message sent by the agent immediately after the WS
    /// upgrade. Includes the agent's self-reported name + labels.
    case register(Register)
    /// Log chunk produced by a step running on the agent.
    case log(LogChunk)
    /// One collected artifact streamed back to the controller. Sent
    /// between the last `.log` chunk and `.buildFinished`. The
    /// controller decodes the base64 payload and persists it under
    /// the build's artifacts dir using the agent-supplied basename.
    case artifact(Artifact)
    /// Final terminal status for a build the agent ran.
    case buildFinished(BuildFinished)
    /// Controller asks the agent to run a build.
    case runBuild(RunBuild)
    /// Controller asks the agent to cancel an in-flight build.
    case cancelBuild(CancelBuild)

    // ──────────────────────────────────────────────────────────────────
    // Nested payloads
    // ──────────────────────────────────────────────────────────────────

    public struct Register: Codable, Sendable, Equatable {
        public let name: String
        public let labels: [String]
        public let agentVersion: String

        public init(name: String, labels: [String] = [], agentVersion: String) {
            self.name = name
            self.labels = labels
            self.agentVersion = agentVersion
        }
    }

    public struct LogChunk: Codable, Sendable, Equatable {
        public let buildID: String
        public let chunk: String

        public init(buildID: String, chunk: String) {
            self.buildID = buildID
            self.chunk = chunk
        }
    }

    /// One collected artifact. `name` is a filesystem-safe basename
    /// (no `/`, no `..`, no drive letters) — the controller's
    /// `JobStore.writeAgentArtifact` rejects anything else. `data`
    /// is the file's bytes base64-encoded for transport over a text
    /// WS frame.
    public struct Artifact: Codable, Sendable, Equatable {
        public let buildID: String
        public let name: String
        public let data: String        // base64

        public init(buildID: String, name: String, data: String) {
            self.buildID = buildID
            self.name = name
            self.data = data
        }
    }

    public struct BuildFinished: Codable, Sendable, Equatable {
        public let buildID: String
        public let status: String   // matches BuildStatus.rawValue
        public let exitCode: Int32

        public init(buildID: String, status: BuildStatus, exitCode: Int32) {
            self.buildID = buildID
            self.status = status.rawValue
            self.exitCode = exitCode
        }
    }

    public struct RunBuild: Codable, Sendable, Equatable {
        public let buildID: String
        public let jobID: String
        public let number: Int
        public let pipeline: Pipeline
        /// Environment variables the agent should overlay on top of
        /// its own process environment + step.env (executor wins, as
        /// in the in-process path).
        public let env: [String: String]

        public init(
            buildID: String, jobID: String, number: Int,
            pipeline: Pipeline, env: [String: String]
        ) {
            self.buildID = buildID
            self.jobID = jobID
            self.number = number
            self.pipeline = pipeline
            self.env = env
        }
    }

    public struct CancelBuild: Codable, Sendable, Equatable {
        public let buildID: String
        public init(buildID: String) {
            self.buildID = buildID
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Codable
    // ──────────────────────────────────────────────────────────────────

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "register":      self = .register(try c.decode(Register.self, forKey: .payload))
        case "log":           self = .log(try c.decode(LogChunk.self, forKey: .payload))
        case "artifact":      self = .artifact(try c.decode(Artifact.self, forKey: .payload))
        case "buildFinished": self = .buildFinished(try c.decode(BuildFinished.self, forKey: .payload))
        case "runBuild":      self = .runBuild(try c.decode(RunBuild.self, forKey: .payload))
        case "cancelBuild":   self = .cancelBuild(try c.decode(CancelBuild.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown agent message type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let p):      try c.encode("register", forKey: .type);      try c.encode(p, forKey: .payload)
        case .log(let p):           try c.encode("log", forKey: .type);           try c.encode(p, forKey: .payload)
        case .artifact(let p):      try c.encode("artifact", forKey: .type);      try c.encode(p, forKey: .payload)
        case .buildFinished(let p): try c.encode("buildFinished", forKey: .type); try c.encode(p, forKey: .payload)
        case .runBuild(let p):      try c.encode("runBuild", forKey: .type);      try c.encode(p, forKey: .payload)
        case .cancelBuild(let p):   try c.encode("cancelBuild", forKey: .type);   try c.encode(p, forKey: .payload)
        }
    }

    /// Encode this message to a UTF-8 string suitable for sending as
    /// a WebSocket text frame.
    public func encodeJSON() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = []   // single-line; clients can pretty-print if they want
        let data = try enc.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Decode a WebSocket text frame into an `AgentMessage`. Throws
    /// `DecodingError` on malformed input.
    public static func decode(json: String) throws -> AgentMessage {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AgentMessage.self, from: data)
    }
}

/// Convenience constructor for `buildID` strings used in the
/// protocol. `<jobID>#<number>` is opaque to the controller and agent
/// alike — they treat it as a free-form identifier — but using a
/// consistent format makes log inspection saner.
public func makeBuildID(jobID: String, number: Int) -> String {
    "\(jobID)#\(number)"
}
