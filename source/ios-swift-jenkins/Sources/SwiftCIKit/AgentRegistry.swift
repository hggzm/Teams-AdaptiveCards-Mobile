import Foundation
import Vapor

/// One connected swiftci-agent on the controller side.
///
/// Wraps the agent's WebSocket and exposes a single `runBuild`
/// method that the executor calls. While a build is running the
/// agent is busy; the registry won't hand the same `RemoteAgent`
/// out to another build until the current one finishes.
///
/// `RemoteAgent` is an actor: incoming WS frames are dispatched
/// onto it via `onText`, and the registry / executor only ever
/// touch its state via actor methods.
public actor RemoteAgent {
    public let id: UUID
    public let name: String
    public let labels: [String]
    public let agentVersion: String

    /// True while this agent is executing a build for the
    /// controller.
    public private(set) var isBusy: Bool = false

    /// True once the agent's WebSocket has closed. Don't dispatch
    /// to a disconnected agent.
    public private(set) var isDisconnected: Bool = false

    /// Per-build accumulator + completion continuation. Populated
    /// when `runBuild` starts; cleared when `buildFinished` arrives
    /// or the WS disconnects.
    private struct InFlight {
        let buildID: String
        var log: String
        var continuation: CheckedContinuation<AgentBuildResult, Never>?
    }
    private var inFlight: InFlight?

    private var artifactHandler: (@Sendable (String, Data) async -> Void)?

    private let ws: WebSocket

    public init(
        id: UUID = UUID(),
        name: String,
        labels: [String],
        agentVersion: String,
        ws: WebSocket
    ) {
        self.id = id
        self.name = name
        self.labels = labels
        self.agentVersion = agentVersion
        self.ws = ws
    }

    // ──────────────────────────────────────────────────────────────────
    // Public API
    // ──────────────────────────────────────────────────────────────────

    /// Send the agent a `runBuild` message and await its terminal
    /// `buildFinished`. Streams every received log chunk to
    /// `onLogChunk` and every collected artifact to `onArtifact` as
    /// they arrive. Returns the final agent status.
    ///
    /// `RemoteAgent.runBuild` does NOT validate that the agent's
    /// labels match anything — the registry does that before
    /// handing the agent out.
    public func runBuild(
        buildID: String,
        jobID: String,
        number: Int,
        pipeline: Pipeline,
        env: [String: String],
        onLogChunk: @escaping @Sendable (String) async -> Void,
        onArtifact: @escaping @Sendable (String, Data) async -> Void
    ) async -> AgentBuildResult {
        guard !isDisconnected else {
            return AgentBuildResult(status: .failed, exitCode: -1,
                                    log: "agent is disconnected\n")
        }
        isBusy = true
        defer { isBusy = false }

        // Install the per-build artifact callback so `receive(_:)` can
        // hand `.artifact` frames to the executor immediately.
        self.artifactHandler = onArtifact
        defer { self.artifactHandler = nil }

        // Stream log chunks via a callback the executor provides, but
        // also accumulate the full text into `inFlight.log` so the
        // final result can include it (handy for tests and for the
        // "build never sent buildFinished" failure case).
        return await withCheckedContinuation { (cont: CheckedContinuation<AgentBuildResult, Never>) in
            self.inFlight = InFlight(buildID: buildID, log: "", continuation: cont)
            Task {
                let msg = AgentMessage.runBuild(.init(
                    buildID: buildID, jobID: jobID, number: number,
                    pipeline: pipeline, env: env))
                if let json = try? msg.encodeJSON() {
                    try? await ws.send(json)
                } else {
                    await self.resumeWithError("could not encode runBuild message")
                }
            }
            // The log callback fires on every received chunk; we hand
            // the executor a closure that wraps the user's callback so
            // RemoteAgent stays in charge of accumulation.
            Task {
                // Wait for buildFinished (or disconnect) by polling
                // for log chunks in a way that pulls them off the
                // actor and calls onLogChunk. We use an unfolding
                // AsyncStream so we don't block this Task.
                let stream = await self.openLogStream(buildID: buildID)
                for await chunk in stream {
                    await onLogChunk(chunk)
                }
            }
        }
    }

    /// Send the agent a `cancelBuild` message. Best-effort: the agent
    /// is responsible for actually terminating its child process and
    /// sending a final `buildFinished` with status `.canceled`.
    public func sendCancel(buildID: String) async {
        let msg = AgentMessage.cancelBuild(.init(buildID: buildID))
        if let json = try? msg.encodeJSON() {
            try? await ws.send(json)
        }
    }

    /// Called by the WS `onText` handler with each frame received
    /// from the agent.
    public func receive(_ frame: String) async {
        guard let msg = try? AgentMessage.decode(json: frame) else {
            // Malformed frame; ignore for MVP.
            return
        }
        switch msg {
        case .log(let chunk):
            await deliverLog(chunk: chunk)
        case .artifact(let payload):
            await deliverArtifact(payload: payload)
        case .buildFinished(let payload):
            await finish(payload: payload)
        case .register, .runBuild, .cancelBuild:
            // Controller doesn't expect these from an already-
            // registered agent. Ignore.
            return
        }
    }

    /// Called when the underlying WS closes. Resumes any in-flight
    /// continuation with a synthetic failure so the executor doesn't
    /// hang forever.
    public func didDisconnect() {
        isDisconnected = true
        if var fl = inFlight {
            let cont = fl.continuation
            fl.continuation = nil
            self.inFlight = fl
            let log = fl.log + "\n[agent disconnected before sending buildFinished]\n"
            cont?.resume(returning: AgentBuildResult(
                status: .failed, exitCode: -1, log: log))
            self.inFlight = nil
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Internals
    // ──────────────────────────────────────────────────────────────────

    private var logStreamContinuation: AsyncStream<String>.Continuation?

    private func openLogStream(buildID: String) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            self.logStreamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.closeLogStream() }
            }
        }
    }

    private func closeLogStream() {
        logStreamContinuation = nil
    }

    private func deliverLog(chunk: AgentMessage.LogChunk) async {
        // Append to inFlight (for the final result) AND forward to
        // the live stream if the executor is consuming it.
        if var fl = inFlight, fl.buildID == chunk.buildID {
            fl.log += chunk.chunk
            self.inFlight = fl
        }
        logStreamContinuation?.yield(chunk.chunk)
    }

    private func deliverArtifact(payload: AgentMessage.Artifact) async {
        guard let fl = inFlight, fl.buildID == payload.buildID else { return }
        guard let data = Data(base64Encoded: payload.data) else { return }
        await artifactHandler?(payload.name, data)
    }

    private func finish(payload: AgentMessage.BuildFinished) async {
        guard var fl = inFlight, fl.buildID == payload.buildID else { return }
        let status = BuildStatus(rawValue: payload.status) ?? .failed
        let cont = fl.continuation
        fl.continuation = nil
        let log = fl.log
        self.inFlight = nil
        logStreamContinuation?.finish()
        logStreamContinuation = nil
        cont?.resume(returning: AgentBuildResult(
            status: status, exitCode: payload.exitCode, log: log))
    }

    private func resumeWithError(_ message: String) async {
        guard var fl = inFlight else { return }
        let cont = fl.continuation
        fl.continuation = nil
        self.inFlight = nil
        cont?.resume(returning: AgentBuildResult(
            status: .failed, exitCode: -1, log: message + "\n"))
    }
}

/// Aggregated outcome of a remote-agent build, returned to the
/// executor.
public struct AgentBuildResult: Sendable, Equatable {
    public let status: BuildStatus
    public let exitCode: Int32
    /// Full log received from the agent. The executor has already
    /// streamed individual chunks via the `onLogChunk` callback, but
    /// this field is handy when the agent disconnected mid-build (the
    /// log captures every chunk that did arrive before the break).
    public let log: String
}

/// Tracks every connected swiftci-agent and hands out idle ones to
/// the executor.
public actor AgentRegistry {
    private var agents: [UUID: RemoteAgent] = [:]

    public init() {}

    public func register(_ agent: RemoteAgent) async {
        await agents[agent.id] = agent
        // NB: actor isolation forces us to access `id` via the
        // existing-actor path; this works because `id` is `let`.
    }

    public func unregister(id: UUID) async {
        agents.removeValue(forKey: id)
    }

    /// Look up an agent by id (used by WS handler to dispatch
    /// incoming frames).
    public func agent(id: UUID) async -> RemoteAgent? {
        agents[id]
    }

    /// Return the first idle, connected agent. The executor calls
    /// this just-in-time; it's a snapshot, not a reservation. The
    /// caller still needs to set `isBusy` (which `RemoteAgent.runBuild`
    /// does automatically).
    public func acquireIdleAgent() async -> RemoteAgent? {
        for (_, agent) in agents {
            let busy = await agent.isBusy
            let disc = await agent.isDisconnected
            if !busy && !disc { return agent }
        }
        return nil
    }

    /// Phase 18: return the first idle, connected agent whose
    /// advertised labels are a SUPERSET of `required`. Matching is
    /// case-sensitive and exact (no glob/regex). When `required` is
    /// empty this is identical to `acquireIdleAgent()`.
    ///
    /// Like `acquireIdleAgent` this is a snapshot, not a reservation;
    /// the caller is responsible for proceeding to `runBuild` (which
    /// flips `isBusy`) on the returned agent.
    public func acquireMatchingAgent(
        labels required: [String]
    ) async -> RemoteAgent? {
        if required.isEmpty {
            return await acquireIdleAgent()
        }
        for (_, agent) in agents {
            let busy = await agent.isBusy
            let disc = await agent.isDisconnected
            guard !busy && !disc else { continue }
            let advertised = Set(agent.labels)
            if required.allSatisfy({ advertised.contains($0) }) {
                return agent
            }
        }
        return nil
    }

    /// Phase 18: true if ANY connected (busy or idle) agent advertises
    /// every label in `required`. Used by the executor to decide
    /// whether to wait in the queue (a matching agent will eventually
    /// free up) versus failing the build outright when no such agent
    /// is even connected.
    public func hasMatchingAgent(
        labels required: [String]
    ) async -> Bool {
        if required.isEmpty { return !agents.isEmpty }
        for (_, agent) in agents {
            let disc = await agent.isDisconnected
            guard !disc else { continue }
            let advertised = Set(agent.labels)
            if required.allSatisfy({ advertised.contains($0) }) {
                return true
            }
        }
        return false
    }

    public var count: Int { agents.count }

    /// Snapshot of every connected agent's public identity (name,
    /// labels, version, busy/disconnected flags). Used by
    /// `GET /api/agents` so operators (and the smoke test) can confirm
    /// an agent has joined before dispatching a build.
    public func snapshot() async -> [AgentInfo] {
        var out: [AgentInfo] = []
        out.reserveCapacity(agents.count)
        for (_, agent) in agents {
            let name = agent.name
            let labels = agent.labels
            let version = agent.agentVersion
            let busy = await agent.isBusy
            let disc = await agent.isDisconnected
            out.append(AgentInfo(
                id: agent.id, name: name, labels: labels,
                agentVersion: version, isBusy: busy,
                isDisconnected: disc))
        }
        out.sort { $0.name < $1.name }
        return out
    }
}

/// Serializable agent description returned by `GET /api/agents`.
public struct AgentInfo: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let labels: [String]
    public let agentVersion: String
    public let isBusy: Bool
    public let isDisconnected: Bool
}
