import Foundation
import NIO
import NIOHTTP1
import WebSocketKit
import SwiftCIKit

/// `swiftci-agent` — connects to a swiftci controller over WebSocket
/// and runs builds that the controller dispatches to it.
///
/// Configuration via environment variables:
///   - `SWIFTCI_CONTROLLER_URL` (required) — e.g.
///     `ws://127.0.0.1:5099/agents` or `wss://ci.example.com/agents`.
///   - `SWIFTCI_AGENT_NAME` — defaults to `<hostname>`.
///   - `SWIFTCI_AGENT_LABELS` — comma-separated labels (informational).
///   - `SWIFTCI_ADMIN_TOKEN` — admin token if the controller has one
///     configured. Sent as `?token=<token>` on the WS URL.
///   - `SWIFTCI_AGENT_WORKSPACE` — root directory for per-build
///     workspaces. Defaults to `<cwd>/swiftci-agent-work`.
///
/// On `runBuild` the agent provisions a clean workspace under
/// `<workspace-root>/<jobID>/<number>/`, runs the pipeline using the
/// shared `StepRunner`, streams every log chunk back as a `log`
/// message, then sends `buildFinished` with the terminal status.
@main
struct AgentMain {
    static let version = SwiftCIApp.version

    static func main() async throws {
        let url = ProcessInfo.processInfo.environment["SWIFTCI_CONTROLLER_URL"]
        guard let url else {
            fputs("error: SWIFTCI_CONTROLLER_URL is required\n", stderr)
            exit(2)
        }
        let token = ProcessInfo.processInfo.environment["SWIFTCI_ADMIN_TOKEN"]
        let name = ProcessInfo.processInfo.environment["SWIFTCI_AGENT_NAME"]
            ?? ProcessInfo.processInfo.hostName
        let labels: [String] = (ProcessInfo.processInfo.environment["SWIFTCI_AGENT_LABELS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let workspaceRoot = ProcessInfo.processInfo.environment["SWIFTCI_AGENT_WORKSPACE"]
            ?? defaultWorkspaceRoot()
        try? FileManager.default.createDirectory(
            atPath: workspaceRoot, withIntermediateDirectories: true)

        let urlWithToken = appendToken(to: url, token: token)
        print("[agent] connecting to \(redacted(urlWithToken))")
        print("[agent] name=\(name) labels=\(labels)")
        print("[agent] workspace=\(workspaceRoot)")

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let session = AgentSession(
            name: name,
            labels: labels,
            workspaceRoot: workspaceRoot)

        do {
            try await WebSocket.connect(
                to: urlWithToken,
                on: elg
            ) { ws in
                // Wire the WS callbacks SYNCHRONOUSLY here — we're
                // running on the WS's event loop, so the
                // `NIOLoopBoundBox` setters are safe. Hopping to the
                // actor's executor (via `Task { await session.bind }`)
                // races against `session.run()` returning early.
                ws.onText { ws, text in
                    Task { await session.handle(text: text) }
                }
                ws.onClose.whenComplete { _ in
                    Task { await session.markDisconnected() }
                }
                // Send the register frame; the controller will reject
                // anything else as the first message.
                let registerMsg = AgentMessage.register(.init(
                    name: name,
                    labels: labels,
                    agentVersion: AgentMain.version
                ))
                if let json = try? registerMsg.encodeJSON() {
                    ws.send(json)
                }
                // Hand the WS reference to the session so it can use
                // it for log/buildFinished frames.
                Task { await session.bind(ws: ws) }
            }.get()
        } catch {
            fputs("error: could not connect: \(error)\n", stderr)
            try? await elg.shutdownGracefully()
            exit(1)
        }

        // Block until the session ends (WS closes / process is killed).
        await session.run()
        print("[agent] disconnected; exiting")
        try? await elg.shutdownGracefully()
    }

    private static func defaultWorkspaceRoot() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        #if os(Windows)
        return "\(cwd)\\swiftci-agent-work"
        #else
        return "\(cwd)/swiftci-agent-work"
        #endif
    }

    /// Append `?token=...` (URL-encoded) if a token is provided.
    private static func appendToken(to url: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return url }
        let encoded = token.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? token
        if url.contains("?") {
            return url + "&token=\(encoded)"
        } else {
            return url + "?token=\(encoded)"
        }
    }

    private static func redacted(_ url: String) -> String {
        // Hide the token from log lines.
        guard let q = url.range(of: "token=") else { return url }
        let prefix = url[..<q.upperBound]
        return String(prefix) + "***"
    }
}

/// Per-process state for the agent. Holds the WS reference and
/// orchestrates each runBuild request the controller sends.
actor AgentSession {
    let name: String
    let labels: [String]
    let workspaceRoot: String
    private var ws: WebSocket?
    private var doneContinuation: AsyncStream<Void>.Continuation?
    private let stepRunner = StepRunner()

    /// Per-build cancel state (Phase 17). The agent serves one build
    /// at a time, so a single set of fields is enough. `currentLatch`
    /// is registered with the running step's `StepRunner.run` call so
    /// `handle(.cancelBuild)` can terminate the child process. The
    /// run loop checks `canceled` between steps and short-circuits.
    private var currentBuildID: String?
    private var currentLatch: ProcessLatch?
    private var canceled: Bool = false

    init(name: String, labels: [String], workspaceRoot: String) {
        self.name = name
        self.labels = labels
        self.workspaceRoot = workspaceRoot
    }

    func bind(ws: WebSocket) {
        self.ws = ws
    }

    /// Block until the WS closes.
    func run() async {
        let stream = AsyncStream<Void> { cont in
            self.doneContinuation = cont
            // Don't auto-finish if `ws` isn't bound yet — `bind(ws:)`
            // may race against `run()` from the WS event loop's
            // upgrade callback. We instead wait for the WS to actually
            // disconnect via `markDisconnected()`.
        }
        for await _ in stream { return }
    }

    func markDisconnected() {
        self.ws = nil
        self.doneContinuation?.finish()
        self.doneContinuation = nil
    }

    func handle(text: String) async {
        guard let msg = try? AgentMessage.decode(json: text) else { return }
        switch msg {
        case .runBuild(let payload):
            await runBuild(payload)
        case .cancelBuild(let payload):
            // Phase 17: real cancel propagation. If the cancel targets
            // the build we're currently running, mark it canceled and
            // terminate the in-flight child process via the shared
            // latch. The runBuild loop will observe `canceled` after
            // the step exits and emit the `.canceled` buildFinished.
            //
            // If we're not running that build (already finished, or
            // never received), silently drop the frame — the
            // controller doesn't need an ack.
            if currentBuildID == payload.buildID {
                canceled = true
                if let latch = currentLatch {
                    await latch.terminate()
                }
            }
        case .register, .log, .buildFinished:
            // Controller doesn't send these.
            return
        case .artifact:
            // Controller doesn't send artifact frames to the agent.
            return
        }
    }

    private func runBuild(_ payload: AgentMessage.RunBuild) async {
        let buildID = payload.buildID
        // Install per-build cancel state. The latch is what lets
        // `handle(.cancelBuild)` kill the in-flight child process; the
        // ID lets us ignore stray cancel frames addressed to a build
        // we're no longer running.
        let latch = ProcessLatch()
        currentBuildID = buildID
        currentLatch = latch
        canceled = false
        defer {
            currentBuildID = nil
            currentLatch = nil
            canceled = false
        }
        // Provision per-build workspace under our root. The
        // controller's `payload.env` includes a `SWIFTCI_WORKSPACE`
        // pointing at the controller's filesystem — override it.
        let myWorkspace: String
        #if os(Windows)
        myWorkspace = "\(workspaceRoot)\\\(payload.jobID)\\\(payload.number)\\workspace"
        #else
        myWorkspace = "\(workspaceRoot)/\(payload.jobID)/\(payload.number)/workspace"
        #endif
        try? FileManager.default.removeItem(atPath: myWorkspace)
        try? FileManager.default.createDirectory(
            atPath: myWorkspace, withIntermediateDirectories: true)

        // Override env paths to point at the agent's filesystem.
        var env = payload.env
        env["SWIFTCI_WORKSPACE"] = myWorkspace
        env["SWIFTCI_AGENT_NAME"] = name

        // Send a leading banner so the controller's log obviously shows
        // the build ran on a remote agent.
        await sendLog(buildID: buildID,
            "[agent: \(name)] starting build #\(payload.number) of \(payload.jobID)\n" +
            "[agent: \(name)] workspace: \(myWorkspace)\n")

        var finalStatus: BuildStatus = .passed
        var finalExitCode: Int32 = 0
        let total = payload.pipeline.steps.count

        let wsURL = URL(fileURLWithPath: myWorkspace, isDirectory: true)
        for (index, step) in payload.pipeline.steps.enumerated() {
            if canceled {
                finalStatus = .canceled
                finalExitCode = -1
                await sendLog(buildID: buildID,
                    "==> step \(index + 1)/\(total): \(step.name): canceled\n")
                break
            }
            // Phase 32: declarative `when {}` gate. Mirrors the
            // controller-side BuildExecutor evaluation. Skipped
            // steps do NOT mark the build failed.
            if let cond = step.condition {
                var merged = env
                for (k, v) in step.env { merged[k] = v }
                if !cond.evaluate(env: merged) {
                    await sendLog(buildID: buildID,
                        "==> step \(index + 1)/\(total): \(step.name): skipped (when condition not met)\n")
                    continue
                }
            }
            await sendLog(buildID: buildID,
                "==> step \(index + 1)/\(total): \(step.name)\n$ \(step.run)\n")
            let result: StepRunner.Result
            do {
                result = try await stepRunner.run(
                    step,
                    workingDirectory: wsURL,
                    environment: env,
                    processLatch: latch)
            } catch {
                await sendLog(buildID: buildID,
                    "step failed to launch: \(error)\n")
                finalStatus = .failed
                finalExitCode = -1
                break
            }
            if !result.output.isEmpty {
                await sendLog(buildID: buildID, result.output)
                if !result.output.hasSuffix("\n") {
                    await sendLog(buildID: buildID, "\n")
                }
            }
            await sendLog(buildID: buildID,
                "==> step \(index + 1)/\(total): exit=\(result.exitCode)\n")
            // A cancel-while-running terminates the child mid-step,
            // which usually surfaces a non-zero exit. Promote to a
            // clean `.canceled` outcome so the controller's view
            // matches operator intent.
            if canceled {
                finalStatus = .canceled
                finalExitCode = -1
                break
            }
            if result.exitCode != 0 {
                finalStatus = .failed
                finalExitCode = result.exitCode
                break
            }

            // Step exited 0: collect declared artifacts and stream
            // them back to the controller. Mirrors the in-process
            // path's "best-effort" behaviour — a missing or unreadable
            // artifact logs a warning and DOES NOT fail the build.
            for path in step.artifacts {
                do {
                    let url = try resolveArtifact(
                        workspace: wsURL, relative: path)
                    let data = try Data(contentsOf: url)
                    let name = url.lastPathComponent
                    await send(.artifact(.init(
                        buildID: buildID,
                        name: name,
                        data: data.base64EncodedString())))
                    await sendLog(buildID: buildID,
                        "   artifact: \(name) (\(path), \(data.count) bytes)\n")
                } catch {
                    await sendLog(buildID: buildID,
                        "   artifact: FAILED to collect '\(path)': \(error)\n")
                }
            }
        }

        await sendLog(buildID: buildID,
            "[agent: \(name)] build #\(payload.number) finished: \(finalStatus.rawValue) (exit=\(finalExitCode))\n")
        await send(.buildFinished(.init(
            buildID: buildID,
            status: finalStatus,
            exitCode: finalExitCode)))
    }

    private func sendLog(buildID: String, _ chunk: String) async {
        await send(.log(.init(buildID: buildID, chunk: chunk)))
    }

    private func send(_ msg: AgentMessage) async {
        guard let ws else { return }
        guard let json = try? msg.encodeJSON() else { return }
        try? await ws.send(json)
    }

    /// Lexical path-traversal guard for the agent's artifact upload.
    /// Matches the controller's `JobStore.collectArtifact` behaviour:
    /// the resolved path must live inside the workspace. Throws so
    /// the caller can log + skip the offending artifact without
    /// failing the build.
    private nonisolated func resolveArtifact(
        workspace: URL,
        relative: String
    ) throws -> URL {
        let candidate = workspace.appendingPathComponent(relative)
        let wsPath = AgentSession.canonical(workspace.path)
        let candPath = AgentSession.canonical(candidate.path)
        guard candPath.hasPrefix(wsPath + AgentSession.sep)
                || candPath == wsPath
        else {
            throw NSError(
                domain: "swiftci-agent", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "artifact path escapes workspace: \(relative)"])
        }
        guard FileManager.default.fileExists(atPath: candPath) else {
            throw NSError(
                domain: "swiftci-agent", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "artifact missing: \(relative)"])
        }
        return URL(fileURLWithPath: candPath)
    }

    #if os(Windows)
    private static let sep = "\\"
    #else
    private static let sep = "/"
    #endif

    /// Lexical-only canonicalization \u2014 same approach as
    /// `JobStore.canonicalPath`. Normalises separator style, flattens
    /// `.` segments, drops trailing separators.
    private static func canonical(_ raw: String) -> String {
        #if os(Windows)
        var s = raw.replacingOccurrences(of: "/", with: "\\")
        #else
        var s = raw
        #endif
        while s.hasSuffix(Self.sep) && s.count > 1 { s.removeLast() }
        return s
    }
}
