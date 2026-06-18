import Foundation

/// In-process build executor.
///
/// v0 semantics (per HANDOFF §6):
///   - Single worker, FIFO queue. No build-level parallelism.
///   - Sequential step execution per build; stop on first non-zero exit.
///   - Build status persisted to disk after every transition so HTTP
///     reads see a consistent view.
///   - Logs streamed to `log.txt` step-by-step (one append per step's
///     completion, plus a banner before/after each step).
///
/// Lifecycle:
///   - `init` does NOT start the worker. Call `start()` once after
///     constructing.
///   - `stop()` cancels the worker task and awaits its completion.
///     Pending builds remain on disk in their last persisted status.
public actor BuildExecutor {
    public let store: JobStore
    public let stepRunner: StepRunner
    public let broadcaster: BuildLogBroadcaster
    public let notifier: BuildNotifier
    /// Registry of connected `swiftci-agent` processes. When a build
    /// is about to run, the worker checks for an idle agent and
    /// dispatches the entire pipeline over WebSocket; if no agent is
    /// connected, the build runs in-process exactly as before.
    public let agents: AgentRegistry
    /// Default per-job build retention when the pipeline doesn't
    /// declare one. After a build reaches a terminal state, the
    /// oldest builds are pruned so at most this many remain per job.
    /// Set to a very high value (e.g. `.max`) to effectively disable.
    public let defaultRetention: Int
    /// Phase 37: optional credential store. When set, steps that
    /// declare `credentials:` get their secret values resolved and
    /// injected into the step's environment. When nil, declaring
    /// any credential bindings fails the build with a clear error.
    public let credentialStore: CredentialStore?

    private var queue: [QueueEntry] = []
    /// Continuations parked in `waitForNext()` waiting for a new
    /// build. Resumed in FIFO order whenever `enqueue(...)` lands a job
    /// while the worker is idle.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var worker: Task<Void, Never>?

    // ──────────────────────────────────────────────────────────────────
    // Per-build cancellation state (Phase 8)
    // ──────────────────────────────────────────────────────────────────

    /// Identifier of the build the worker is currently executing, or
    /// nil when the worker is idle / between steps.
    private var currentBuild: QueueEntry?
    /// Latch shared with `StepRunner` for the currently running step.
    /// The executor calls `terminate()` on it to cancel the child
    /// process.
    private var currentLatch: ProcessLatch?
    /// Remote agent the currently running build is dispatched to, or
    /// nil when the build is running in-process. `cancel()` uses this
    /// to send a `.cancelBuild` frame so the agent terminates its own
    /// child process and reports back with a `.canceled` status.
    private var currentAgent: RemoteAgent?
    /// Build identifier sent to the agent for the currently dispatched
    /// build (only set when `currentAgent != nil`). Used by `cancel()`
    /// when forwarding the cancel frame.
    private var currentAgentBuildID: String?
    /// `cancel(jobID:number:)` sets this when the running build's
    /// step has been killed. `runBuild` checks it between steps and
    /// short-circuits with `.canceled`.
    private var cancellationRequested: Bool = false

    public init(
        store: JobStore,
        stepRunner: StepRunner = StepRunner(),
        broadcaster: BuildLogBroadcaster = BuildLogBroadcaster(),
        notifier: BuildNotifier = NoopBuildNotifier(),
        agents: AgentRegistry = AgentRegistry(),
        defaultRetention: Int = 50,
        credentialStore: CredentialStore? = nil
    ) {
        self.store = store
        self.stepRunner = stepRunner
        self.broadcaster = broadcaster
        self.notifier = notifier
        self.agents = agents
        self.defaultRetention = max(1, defaultRetention)
        self.credentialStore = credentialStore
    }

    // ──────────────────────────────────────────────────────────────────
    // Public API
    // ──────────────────────────────────────────────────────────────────

    /// Allocate the next build number for `jobID`, persist it as
    /// `queued`, enqueue it, and return the assigned number. Throws if
    /// the job does not exist on disk.
    ///
    /// If `webhookPayload` is non-nil it is written to
    /// `<build-dir>/webhook.json` BEFORE the worker picks the build
    /// up, so steps can rely on `SWIFTCI_WEBHOOK_BODY_PATH` always
    /// pointing at a real file when one was supplied.
    @discardableResult
    public func enqueue(
        jobID: String,
        webhookPayload: WebhookPayload? = nil,
        parameters: [String: String]? = nil
    ) throws -> Int {
        var build = try store.createBuild(jobID: jobID)
        if let webhookPayload {
            try store.writeWebhookPayload(
                jobID: jobID, number: build.number, payload: webhookPayload)
        }
        // Phase 33: persist trigger-time parameter overrides on the
        // Build so they show up in `GET /api/jobs/:id/builds/:n` and
        // survive controller restarts before the worker picks the
        // entry up.
        if let parameters, !parameters.isEmpty {
            build.parameters = parameters
            try store.updateBuild(build)
        }
        // `build.queuedAt` is stamped by `JobStore.createBuild` (Phase
        // 21) and is what we use to compute queue-wait time. Falling
        // back to `Date()` here keeps a defined value if a future
        // refactor ever drops the field — the only observable effect
        // is a marginally later timestamp than the persisted one.
        queue.append(QueueEntry(jobID: jobID, number: build.number,
                                hasWebhookPayload: webhookPayload != nil,
                                queuedAt: build.queuedAt ?? Date(),
                                parameters: build.parameters))
        // Wake one waiter (the worker).
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            w.resume()
        }
        return build.number
    }

    /// Start the worker task. Idempotent — repeated calls are no-ops.
    public func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.workerLoop()
        }
    }

    /// Cancel the worker task and wait for it to finish.
    ///
    /// The worker may be parked inside `waitForNext()` on a checked
    /// continuation — `Task.cancel()` alone won't wake it, so we drain
    /// the parked waiters BEFORE awaiting the worker. After this method
    /// returns, the worker task is gone and the executor will not
    /// accept new builds until `start()` is called again.
    public func stop() async {
        worker?.cancel()
        let parked = waiters
        waiters.removeAll()
        for w in parked { w.resume() }
        await worker?.value
        worker = nil
    }

    /// Number of builds currently waiting in the queue (for tests /
    /// diagnostics).
    public var queueDepth: Int { queue.count }

    /// Phase 22: snapshot of the executor's FIFO queue, in head-first
    /// order. `position` is 1-based (the build at the head of the
    /// queue is `position: 1`, the next build the worker will pick
    /// up after the currently running one finishes). `queuedAt` is
    /// the timestamp recorded when the build was first enqueued, and
    /// is preserved across agent-label requeues so the reported wait
    /// time reflects the original arrival.
    public func snapshotQueue() -> [QueueSnapshotEntry] {
        queue.enumerated().map { (idx, e) in
            QueueSnapshotEntry(
                jobID: e.jobID,
                number: e.number,
                position: idx + 1,
                queuedAt: e.queuedAt
            )
        }
    }

    /// Public projection of a queued build, exposed via the
    /// `/api/queue` endpoint. Mirrors the bits of `QueueEntry`
    /// callers actually care about.
    public struct QueueSnapshotEntry: Codable, Equatable, Sendable {
        public var jobID: String
        public var number: Int
        /// 1-based position in the queue (head = 1).
        public var position: Int
        public var queuedAt: Date

        public init(jobID: String, number: Int, position: Int, queuedAt: Date) {
            self.jobID = jobID
            self.number = number
            self.position = position
            self.queuedAt = queuedAt
        }
    }

    /// Outcome of a `cancel(jobID:number:)` call.
    public enum CancelResult: Sendable, Equatable {
        /// The build was the currently-running one and its step has
        /// been signaled to terminate. The on-disk status will flip to
        /// `.canceled` shortly (after `waitUntilExit` returns).
        case canceledRunning
        /// The build was waiting in the queue. It has been removed
        /// from the queue, persisted as `.canceled`, and its log
        /// stream finished. No step ever ran.
        case canceledQueued
        /// The build doesn't exist OR is already in a terminal state
        /// (`.passed` / `.failed` / `.canceled`). Caller should
        /// surface 404 vs 409.
        case notCancellable
    }

    /// Cancel a build by `(jobID, number)`. Idempotent: a second call
    /// on an already-canceled build returns `.notCancellable`.
    public func cancel(jobID: String, number: Int) async -> CancelResult {
        // 0. If the on-disk status is already terminal, treat as
        // non-cancellable. This races cleanly with the worker: by the
        // time `runBuild` writes the terminal status, we want this
        // method to stop pretending the build is still running, even
        // if the worker's `defer` hasn't reset `currentBuild` yet.
        if let existing = try? store.loadBuild(jobID: jobID, number: number),
           existing.status.isTerminal {
            return .notCancellable
        }
        // 1. Currently running?
        if let cur = currentBuild, cur.jobID == jobID, cur.number == number {
            cancellationRequested = true
            // Forward the cancel to whichever execution surface owns
            // the in-flight step. Exactly one of these is wired at a
            // time: agent-dispatched builds have `currentAgent` set
            // and the in-process latch left unused; in-process builds
            // have `currentLatch` registered with the running child
            // and `currentAgent` nil. Both calls are safe no-ops
            // when their target isn't engaged.
            if let agent = currentAgent, let buildID = currentAgentBuildID {
                await agent.sendCancel(buildID: buildID)
            }
            if let latch = currentLatch {
                await latch.terminate()
            }
            return .canceledRunning
        }
        // 2. In queue? Drop + mark canceled on disk.
        if let idx = queue.firstIndex(where: { $0.jobID == jobID && $0.number == number }) {
            queue.remove(at: idx)
            var build = (try? store.loadBuild(jobID: jobID, number: number))
                ?? Build(jobID: jobID, number: number, status: .canceled)
            build.status = .canceled
            build.exitCode = -1
            build.endedAt = Date()
            try? store.updateBuild(build)
            try? store.appendLog(jobID: jobID, number: number,
                "=== build #\(number) canceled while queued ===\n")
            await broadcaster.finish(jobID: jobID, number: number)
            // Fire notifications for queued-cancel too. Best-effort:
            // we may not have the pipeline if loadJob fails, in which
            // case there's nothing to notify.
            if let pipeline = try? store.loadJob(id: jobID) {
                await notifier.notify(build: build, pipeline: pipeline)
                prune(jobID: jobID, pipeline: pipeline)
            }
            return .canceledQueued
        }
        // 3. Otherwise: unknown OR already terminal.
        return .notCancellable
    }

    // ──────────────────────────────────────────────────────────────────
    // Worker
    // ──────────────────────────────────────────────────────────────────

    private struct QueueEntry: Sendable, Equatable {
        let jobID: String
        let number: Int
        let hasWebhookPayload: Bool
        /// Phase 22: when this entry was first enqueued. Preserved
        /// across agent-label requeues so `/api/queue` reports the
        /// original arrival time, not the time of the latest requeue.
        let queuedAt: Date
        /// Phase 33: trigger-time parameter overrides, merged into
        /// `stdEnv` BEFORE `SWIFTCI_*` keys so the controller's
        /// reserved env always wins but Phase-24 `parameters{}`
        /// defaults (which live in `step.env`) are overridden.
        let parameters: [String: String]?
    }

    private func workerLoop() async {
        while !Task.isCancelled {
            // Pull next.
            let entry: QueueEntry
            if let head = queue.first {
                queue.removeFirst()
                entry = head
            } else {
                await waitForNext()
                continue
            }
            await runBuild(entry: entry)
        }
    }

    private func waitForNext() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if Task.isCancelled {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }

    private func runBuild(entry: QueueEntry) async {
        let jobID = entry.jobID
        let number = entry.number

        // Load the pipeline.
        let pipeline: Pipeline?
        do {
            pipeline = try store.loadJob(id: jobID)
        } catch {
            await mark(jobID: jobID, number: number, status: .failed, exitCode: -1,
                       reason: "could not load pipeline: \(error)")
            return
        }
        guard let pipeline else {
            await mark(jobID: jobID, number: number, status: .failed, exitCode: -1,
                       reason: "no such job: \(jobID)")
            return
        }

        // Phase 18: agent-label gating. When the pipeline declares
        // required labels, the build MUST run on a remote agent whose
        // advertised labels are a superset.
        //
        // - Idle matching agent? Fall through and let the dispatch
        //   branch below pick it up.
        // - Busy matching agent (or no idle one yet)? Requeue at the
        //   tail and yield, so the worker can pick the next build up.
        //   The build stays `.queued` on disk (we have not yet
        //   transitioned to `.running`).
        // - No agent with the required labels is even connected? Fail
        //   immediately so operators see the misconfiguration instead
        //   of a build queued forever.
        if !pipeline.agentLabels.isEmpty {
            let idleMatch = await agents.acquireMatchingAgent(
                labels: pipeline.agentLabels) != nil
            if !idleMatch {
                let anyMatch = await agents.hasMatchingAgent(
                    labels: pipeline.agentLabels)
                if !anyMatch {
                    await mark(jobID: jobID, number: number,
                        status: .failed, exitCode: -1,
                        reason: "no connected agent advertises required labels: " +
                                pipeline.agentLabels.joined(separator: ","))
                    return
                }
                // Matching agent exists but is currently busy.
                // Requeue ourselves at the tail. Sleep briefly so we
                // don't burn CPU spinning when the busy build is long.
                queue.append(entry)
                try? await Task.sleep(for: .milliseconds(250))
                return
            }
        }

        // Provision a clean workspace directory for this build. The
        // workspace is wiped and recreated so re-runs of the same
        // build number (today only possible via direct API misuse) get
        // a fresh tree.
        let workspaceURL: URL
        do {
            workspaceURL = try store.provisionWorkspace(jobID: jobID, number: number)
        } catch {
            await mark(jobID: jobID, number: number, status: .failed, exitCode: -1,
                       reason: "could not provision workspace: \(error)")
            return
        }

        // Phase 34: pipeline-from-SCM. When the controller-side
        // pipeline declares an `scm:` source, clone the repository
        // into the workspace and read the effective pipeline (steps,
        // when{} gates, env, agent labels…) from the Jenkinsfile inside
        // the clone. The decoder rejects pipelines that combine `scm:`
        // with `agentLabels:`, so by the time we get here the build
        // is committed to in-process execution; we still defensively
        // skip remote-agent dispatch below for SCM-driven builds.
        let effectivePipeline: Pipeline
        if let scm = pipeline.scm {
            let header = "=== scm: cloning \(scm.git.url) @ \(scm.git.ref) ===\n"
            await log(jobID: jobID, number: number, header)
            do {
                let r = try SCMCheckout.checkoutAndLoad(
                    scm: scm, original: pipeline, workspace: workspaceURL)
                await log(jobID: jobID, number: number, r.log)
                for w in r.warnings {
                    await log(jobID: jobID, number: number,
                        "scm: jenkinsfile warning: \(w)\n")
                }
                await log(jobID: jobID, number: number,
                    "=== scm: pipeline loaded from \(scm.jenkinsfile) " +
                    "(\(r.pipeline.steps.count) step\(r.pipeline.steps.count == 1 ? "" : "s")) ===\n")
                effectivePipeline = r.pipeline
            } catch {
                await log(jobID: jobID, number: number,
                    "=== scm: \(error) ===\n")
                await mark(jobID: jobID, number: number,
                    status: .failed, exitCode: -1,
                    reason: "scm checkout failed: \(error)")
                return
            }
        } else {
            effectivePipeline = pipeline
        }

        // Standard environment exposed to every step. The executor
        // applies these LAST, so they cannot be shadowed by step-level
        // `env:` keys.
        //
        // Phase 33: trigger-time `parameters` are seeded first, then
        // overwritten by the reserved `SWIFTCI_*` keys. Net effect:
        // user-supplied parameters override `step.env` (which carries
        // Phase-24 `parameters{}` defaults), but they cannot shadow
        // controller-reserved env.
        var stdEnv: [String: String] = [:]
        if let params = entry.parameters {
            for (k, v) in params { stdEnv[k] = v }
        }
        stdEnv["SWIFTCI_JOB_ID"]       = jobID
        stdEnv["SWIFTCI_BUILD_NUMBER"] = String(number)
        stdEnv["SWIFTCI_WORKSPACE"]    = workspaceURL.path
        stdEnv["SWIFTCI_BUILD_DIR"]    = store.buildDir(jobID: jobID, number: number).path
        if entry.hasWebhookPayload {
            let payloadURL = store.webhookPayloadURL(jobID: jobID, number: number)
            stdEnv["SWIFTCI_WEBHOOK_BODY_PATH"] = payloadURL.path
        }

        // Install cancellation state for this build BEFORE persisting
        // the `.running` status. Otherwise a cancel() call that lands
        // between the on-disk `.running` write and `currentBuild =
        // entry` would see `.running` on disk (so refuse to bail) but
        // find `currentBuild == nil` (so return .notCancellable). The
        // `defer` clears the state so a panic mid-step still releases
        // the latch.
        let latch = ProcessLatch()
        currentBuild = entry
        currentLatch = latch
        currentAgent = nil
        currentAgentBuildID = nil
        cancellationRequested = false
        defer {
            currentBuild = nil
            currentLatch = nil
            currentAgent = nil
            currentAgentBuildID = nil
            cancellationRequested = false
        }

        // Mark running on disk. Load the persisted build first so
        // queuedAt and Phase-33 `parameters` are preserved across the
        // queued → running transition; fall back to a fresh struct if
        // the on-disk record is missing.
        var build = (try? store.loadBuild(jobID: jobID, number: number))
            ?? Build(jobID: jobID, number: number, status: .running,
                     startedAt: Date())
        build.status = .running
        build.startedAt = Date()
        do { try store.updateBuild(build) } catch { /* best-effort */ }
        await log(jobID: jobID, number: number,
            "=== build #\(number) of \(jobID) started at \(build.startedAt!.iso8601) ===\n")
        await log(jobID: jobID, number: number,
            "workspace: \(workspaceURL.path)\n")

        var finalStatus: BuildStatus = .passed
        var finalExitCode: Int32 = 0
        let total = effectivePipeline.steps.count

        // ──────────────────────────────────────────────────────────────
        // Branch: remote agent if one is idle (Phase 18: matching the
        // pipeline's required labels, when set), otherwise in-process.
        //
        // The label gate above already requeued or failed the build
        // if no matching agent could ever serve it. The acquisition
        // here can still race against an agent disconnecting between
        // gate and dispatch — in that vanishingly rare case we mark
        // the build failed rather than silently falling back to
        // in-process (which would defeat the whole point of labels).
        // ──────────────────────────────────────────────────────────────
        let acquired: RemoteAgent?
        if effectivePipeline.scm != nil {
            // Phase 34: SCM-driven builds always run in-process. The
            // workspace clone happened above on the controller; remote
            // agents have their own (empty) workspaces and would not
            // see the cloned tree.
            acquired = nil
        } else if effectivePipeline.agentLabels.isEmpty {
            acquired = await agents.acquireIdleAgent()
        } else {
            acquired = await agents.acquireMatchingAgent(
                labels: effectivePipeline.agentLabels)
        }
        if effectivePipeline.agentLabels.isEmpty == false && acquired == nil {
            await log(jobID: jobID, number: number,
                "ERROR: matching agent vanished between gate and dispatch\n")
            finalStatus = .failed
            finalExitCode = -1
            // Skip the dispatch branch entirely; the trailing terminal-
            // status write below handles persistence + notify + prune.
        } else if let agent = acquired {
            let agentName = await agent.name
            await log(jobID: jobID, number: number,
                "dispatch: remote agent '\(agentName)'\n")
            let buildID = makeBuildID(jobID: jobID, number: number)
            // Register so `cancel()` can forward a cancel frame to the
            // agent. Cleared by the same defer that drops `currentBuild`.
            currentAgent = agent
            currentAgentBuildID = buildID
            let result = await agent.runBuild(
                buildID: buildID,
                jobID: jobID,
                number: number,
                pipeline: effectivePipeline,
                env: stdEnv
            ) { [weak self] chunk in
                // Stream every chunk the agent sends back to disk +
                // the local broadcaster. The agent's log is authoritative
                // for the in-flight build.
                await self?.log(jobID: jobID, number: number, chunk)
            } onArtifact: { [weak self] name, data in
                // Persist agent-uploaded artifacts via the store. Any
                // error here is non-fatal — log and continue.
                guard let self else { return }
                do {
                    _ = try self.store.writeAgentArtifact(
                        jobID: jobID, number: number,
                        name: name, data: data)
                } catch {
                    await self.log(jobID: jobID, number: number,
                        "   artifact: FAILED to persist '\(name)' on controller: \(error)\n")
                }
            }
            finalStatus = result.status
            finalExitCode = result.exitCode
            // If the controller asked for cancel but the agent reported
            // `.failed` (older agents, or the child died before the
            // agent could promote the status), normalise to `.canceled`
            // so on-disk + notifier state matches operator intent.
            if cancellationRequested && finalStatus != .canceled {
                finalStatus = .canceled
                finalExitCode = -1
            }
            // Remote-agent builds receive artifacts via streamed
            // `.artifact` frames (handled in onArtifact above), so the
            // controller's filesystem view is in sync by the time we
            // get here.
        } else {

        for (index, step) in effectivePipeline.steps.enumerated() {
            if cancellationRequested || Task.isCancelled {
                finalStatus = .canceled
                finalExitCode = -1
                await log(jobID: jobID, number: number,
                    "==> step \(index + 1)/\(total): \(step.name): canceled\n")
                break
            }
            // Phase 32: declarative `when {}` gate. Evaluate against
            // the merged build env (stdEnv ∪ step.env). Skipped steps
            // do NOT count as failures and do NOT collect artifacts.
            if let cond = step.condition {
                var merged = stdEnv
                for (k, v) in step.env { merged[k] = v }
                if !cond.evaluate(env: merged) {
                    await log(jobID: jobID, number: number,
                        "==> step \(index + 1)/\(total): \(step.name): skipped (when condition not met)\n")
                    continue
                }
            }
            // Phase 36: parallel group. Fan branches out via a
            // TaskGroup, each branch runs its sub-steps sequentially,
            // any branch failure fails the group. Branch output is
            // captured per-branch and emitted contiguously with a
            // `[branch] ` prefix to keep the build log readable.
            if let branches = step.parallel {
                await log(jobID: jobID, number: number,
                    "==> step \(index + 1)/\(total): \(step.name): parallel (\(branches.count) branch\(branches.count == 1 ? "" : "es"))\n")
                let outcome = await runParallel(
                    branches: branches,
                    workspaceURL: workspaceURL,
                    stdEnv: stdEnv,
                    latch: latch,
                    jobID: jobID,
                    number: number,
                    stepIndex: index,
                    totalSteps: total
                )
                if cancellationRequested {
                    finalStatus = .canceled
                    finalExitCode = -1
                    break
                }
                if !outcome.passed {
                    finalStatus = .failed
                    finalExitCode = outcome.exitCode
                    break
                }
                continue
            }
            await log(jobID: jobID, number: number,
                "==> step \(index + 1)/\(total): \(step.name)\n$ \(step.run)\n")

            // Phase 37: resolve `credentials:` for this step against
            // the controller's CredentialStore. Resolution failures
            // (unknown id, store not configured) fail the build
            // BEFORE the child process is launched so secret-less
            // commands don't run with the binding silently empty.
            var stepEnv = stdEnv
            if !step.credentials.isEmpty {
                let resolved: [String: String]
                do {
                    resolved = try await resolveCredentials(
                        step.credentials, jobID: jobID, number: number,
                        stepName: step.name)
                } catch {
                    await log(jobID: jobID, number: number,
                        "step credential resolution failed: \(error)\n")
                    finalStatus = .failed
                    finalExitCode = -1
                    break
                }
                for (k, v) in resolved { stepEnv[k] = v }
            }

            let result: StepRunner.Result
            do {
                result = try await stepRunner.run(
                    step,
                    workingDirectory: workspaceURL,
                    environment: stepEnv,
                    processLatch: latch
                )
            } catch {
                await log(jobID: jobID, number: number,
                    "step failed to launch: \(error)\n")
                finalStatus = .failed
                finalExitCode = -1
                break
            }

            await log(jobID: jobID, number: number, result.output)
            if !result.output.isEmpty && !result.output.hasSuffix("\n") {
                await log(jobID: jobID, number: number, "\n")
            }
            await log(jobID: jobID, number: number,
                "==> step \(index + 1)/\(total): exit=\(result.exitCode)\n")

            // A cancel-while-running terminates the child mid-step,
            // which usually produces a non-zero exit. Promote that to
            // a clean `.canceled` outcome rather than `.failed`.
            if cancellationRequested {
                finalStatus = .canceled
                finalExitCode = -1
                break
            }

            if result.exitCode != 0 {
                finalStatus = .failed
                finalExitCode = result.exitCode
                break
            }

            // Step succeeded → collect declared artifacts. Failure to
            // collect is logged but doesn't fail the build (matches
            // Jenkins's "best-effort" artifact behaviour).
            for path in step.artifacts {
                do {
                    let collected = try store.collectArtifact(
                        jobID: jobID, number: number, relativePath: path)
                    await log(jobID: jobID, number: number,
                        "   artifact: \(collected.lastPathComponent) (\(path))\n")
                } catch {
                    await log(jobID: jobID, number: number,
                        "   artifact: FAILED to collect '\(path)': \(error)\n")
                }
            }
        }
        }   // end of `else` (in-process path)

        build.status = finalStatus
        build.exitCode = finalExitCode
        build.endedAt = Date()
        do { try store.updateBuild(build) } catch { /* best-effort */ }
        await log(jobID: jobID, number: number,
            "=== build #\(number) finished: \(finalStatus.rawValue) (exit=\(finalExitCode)) at \(build.endedAt!.iso8601) ===\n")
        await broadcaster.finish(jobID: jobID, number: number)
        await notifier.notify(build: build, pipeline: pipeline)
        prune(jobID: jobID, pipeline: pipeline)
        await fireTriggersIfPassed(build: build, pipeline: pipeline)
    }

    /// Append a chunk to the build's `log.txt` AND publish it to live
    /// subscribers. Both sides are best-effort: a disk error doesn't
    /// stop the broadcast, and an empty broadcast doesn't fail the
    /// disk write.
    private func log(jobID: String, number: Int, _ chunk: String) async {
        try? store.appendLog(jobID: jobID, number: number, chunk)
        await broadcaster.publish(jobID: jobID, number: number, chunk)
    }

    /// Phase 36 outcome of one parallel-group step.
    private struct ParallelOutcome {
        let passed: Bool
        let exitCode: Int32
    }

    /// Phase 36: fan one `parallel:` step out across branches via a
    /// `TaskGroup`. Each branch runs its sub-steps sequentially using
    /// `stepRunner`. Per-branch output is buffered and flushed to the
    /// build log as a single contiguous block once that branch
    /// finishes — so concurrent branches don't interleave each
    /// other's stdout. A `[branch] ` prefix on every line keeps the
    /// log readable. The group passes only when every branch's last
    /// sub-step exits 0.
    private func runParallel(
        branches: [Pipeline.ParallelBranch],
        workspaceURL: URL,
        stdEnv: [String: String],
        latch: ProcessLatch,
        jobID: String,
        number: Int,
        stepIndex: Int,
        totalSteps: Int
    ) async -> ParallelOutcome {
        struct BranchResult: Sendable {
            let name: String
            let passed: Bool
            let exitCode: Int32
            let log: String
        }
        // Phase 37: pre-resolve credentials for every sub-step in
        // every branch up-front. Resolution failures fail the group
        // (and the build) before any branch is launched. The
        // resolved env map for each sub-step is then passed into the
        // detached task — this keeps the actor-isolated
        // `credentialStore` off the parallel hot path.
        var resolvedPerBranch: [[[String: String]]] = []
        resolvedPerBranch.reserveCapacity(branches.count)
        for branch in branches {
            var perSub: [[String: String]] = []
            perSub.reserveCapacity(branch.steps.count)
            for sub in branch.steps {
                if sub.credentials.isEmpty {
                    perSub.append([:])
                    continue
                }
                do {
                    let r = try await resolveCredentials(
                        sub.credentials, jobID: jobID, number: number,
                        stepName: "\(branch.name)/\(sub.name)")
                    perSub.append(r)
                } catch {
                    await log(jobID: jobID, number: number,
                        "parallel branch '\(branch.name)' sub '\(sub.name)' credential resolution failed: \(error)\n")
                    return ParallelOutcome(passed: false, exitCode: -1)
                }
            }
            resolvedPerBranch.append(perSub)
        }
        let stepRunner = self.stepRunner
        let results: [BranchResult] = await withTaskGroup(
            of: BranchResult.self,
            returning: [BranchResult].self
        ) { group in
            for (bIdx, branch) in branches.enumerated() {
                let resolved = resolvedPerBranch[bIdx]
                group.addTask {
                    var transcript = ""
                    transcript += "==> [\(branch.name)] started (\(branch.steps.count) sub-step\(branch.steps.count == 1 ? "" : "s"))\n"
                    var branchExit: Int32 = 0
                    var branchPassed = true
                    for (j, sub) in branch.steps.enumerated() {
                        if Task.isCancelled {
                            transcript += "==> [\(branch.name)] sub \(j + 1)/\(branch.steps.count): \(sub.name): canceled\n"
                            branchPassed = false
                            branchExit = -1
                            break
                        }
                        if let cond = sub.condition {
                            var merged = stdEnv
                            for (k, v) in sub.env { merged[k] = v }
                            if !cond.evaluate(env: merged) {
                                transcript += "==> [\(branch.name)] sub \(j + 1)/\(branch.steps.count): \(sub.name): skipped (when condition not met)\n"
                                continue
                            }
                        }
                        transcript += "==> [\(branch.name)] sub \(j + 1)/\(branch.steps.count): \(sub.name)\n$ \(sub.run)\n"
                        do {
                            // The latch is shared with the executor's
                            // single in-flight step model; parallel
                            // branches deliberately do NOT install
                            // themselves into the latch, so a cancel
                            // request only terminates whichever child
                            // was most recently started. The cooperative
                            // Task.isCancelled check above is what
                            // unwinds every branch on cancel.
                            var subEnv = stdEnv
                            for (k, v) in resolved[j] { subEnv[k] = v }
                            let r = try await stepRunner.run(
                                sub,
                                workingDirectory: workspaceURL,
                                environment: subEnv,
                                processLatch: nil
                            )
                            var chunk = r.output
                            if chunk.hasSuffix("\n") {
                                chunk.removeLast()
                            }
                            if !chunk.isEmpty {
                                let prefixed = chunk
                                    .split(separator: "\n",
                                           omittingEmptySubsequences: false)
                                    .map { "    [\(branch.name)] \($0)" }
                                    .joined(separator: "\n")
                                transcript += prefixed
                                transcript += "\n"
                            }
                            transcript += "==> [\(branch.name)] sub \(j + 1)/\(branch.steps.count): exit=\(r.exitCode)\n"
                            if r.exitCode != 0 {
                                branchPassed = false
                                branchExit = r.exitCode
                                break
                            }
                        } catch {
                            transcript += "==> [\(branch.name)] sub \(j + 1)/\(branch.steps.count): launch failed: \(error)\n"
                            branchPassed = false
                            branchExit = -1
                            break
                        }
                    }
                    transcript += "==> [\(branch.name)] finished: \(branchPassed ? "passed" : "failed")\n"
                    _ = latch  // silence "unused" while keeping the parameter for future cancel wiring
                    return BranchResult(
                        name: branch.name,
                        passed: branchPassed,
                        exitCode: branchExit,
                        log: transcript)
                }
            }
            var collected: [BranchResult] = []
            for await r in group { collected.append(r) }
            return collected
        }
        // Emit each branch's transcript contiguously, in declaration
        // order, so the build log reads predictably regardless of
        // which branch finished first.
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        var groupPassed = true
        var groupExit: Int32 = 0
        for branch in branches {
            guard let r = byName[branch.name] else { continue }
            await log(jobID: jobID, number: number, r.log)
            if !r.passed {
                groupPassed = false
                if groupExit == 0 { groupExit = r.exitCode }
            }
        }
        await log(jobID: jobID, number: number,
            "==> step \(stepIndex + 1)/\(totalSteps): parallel group \(groupPassed ? "passed" : "failed")\n")
        return ParallelOutcome(passed: groupPassed, exitCode: groupExit)
    }

    /// Phase 37: resolve a step's credential bindings against the
    /// controller's `CredentialStore`. The returned map is the env
    /// overlay (variable → secret value). Throws on missing store
    /// or unknown id. The build log records the resolved variable
    /// names but NEVER their values.
    enum CredentialError: Error, CustomStringConvertible {
        case noStore
        case unknownID(String)
        var description: String {
            switch self {
            case .noStore:
                return "credentials: declared but no credential store is configured on the controller"
            case .unknownID(let id):
                return "credentials: no credential with id '\(id)' is registered"
            }
        }
    }

    private func resolveCredentials(
        _ bindings: [Pipeline.CredentialBinding],
        jobID: String, number: Int, stepName: String
    ) async throws -> [String: String] {
        guard let store = credentialStore else { throw CredentialError.noStore }
        var out: [String: String] = [:]
        for b in bindings {
            guard let cred = try await store.lookup(id: b.credentialsId) else {
                throw CredentialError.unknownID(b.credentialsId)
            }
            out[b.variable] = cred.value
        }
        let names = bindings.map(\.variable).joined(separator: ", ")
        await log(jobID: jobID, number: number,
            "   credentials: bound [\(names)] for '\(stepName)'\n")
        return out
    }

    private func mark(jobID: String, number: Int, status: BuildStatus,
                      exitCode: Int32, reason: String) async {
        var b = (try? store.loadBuild(jobID: jobID, number: number))
            ?? Build(jobID: jobID, number: number, status: status)
        b.status = status
        b.exitCode = exitCode
        b.endedAt = Date()
        try? store.updateBuild(b)
        await log(jobID: jobID, number: number, "ERROR: \(reason)\n")
        await broadcaster.finish(jobID: jobID, number: number)
        // Best-effort: notify if we can load the pipeline; if not
        // (e.g. the very reason we ended up here was loadJob failing),
        // skip silently.
        if let pipeline = try? store.loadJob(id: jobID) {
            await notifier.notify(build: b, pipeline: pipeline)
            prune(jobID: jobID, pipeline: pipeline)
        }
    }

    /// Apply the pipeline's (or executor's) build-retention policy.
    /// Always best-effort — prune failures don't affect the build
    /// outcome. Called from every terminal-state path so disk usage
    /// stays bounded regardless of how the build ended.
    private func prune(jobID: String, pipeline: Pipeline) {
        let keep = pipeline.retention?.maxBuilds ?? defaultRetention
        _ = try? store.pruneBuilds(jobID: jobID, keepLast: keep)
    }

    /// Enqueue each downstream job listed in `pipeline.triggers` when
    /// the upstream build's terminal status is `.passed`. Best-effort:
    /// missing or already-purged downstream jobs log an inline note
    /// in the upstream build's log but do not change its outcome.
    ///
    /// Triggers are queued via the public `enqueue` path so they
    /// flow through the same FIFO + worker + notifier + retention
    /// machinery as any other build.
    private func fireTriggersIfPassed(build: Build, pipeline: Pipeline) async {
        guard build.status == .passed, !pipeline.triggers.isEmpty else { return }
        for downstreamID in pipeline.triggers {
            do {
                let n = try enqueue(jobID: downstreamID)
                await log(jobID: build.jobID, number: build.number,
                    "trigger: enqueued downstream '\(downstreamID)' as build #\(n)\n")
            } catch {
                await log(jobID: build.jobID, number: build.number,
                    "trigger: FAILED to enqueue downstream '\(downstreamID)': \(error)\n")
            }
        }
    }
}

extension Date {
    fileprivate var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
