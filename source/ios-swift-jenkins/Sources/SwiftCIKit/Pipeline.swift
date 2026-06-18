import Foundation
import Yams

/// A parsed pipeline definition.
///
/// Schema is intentionally narrow for v0 — only `name` + a list of named
/// `run` steps. Compatible with the example in the
/// `bucket/HANDOFF-swiftci-jenkins-windows-2026-05-18.md` §4 sketch and
/// with a useful subset of GitHub Actions' workflow YAML.
///
/// Future schema extensions will live behind a `version: 0.x` discriminator
/// at the top level so older pipelines keep parsing.
public struct Pipeline: Codable, Hashable, Sendable {
    public let name: String
    public let steps: [Step]
    /// Pipeline-level outbound notifications. Fired after the build
    /// reaches a terminal state (`.passed` / `.failed` / `.canceled`).
    /// Optional in YAML; defaults to empty.
    public let notify: [Notification]
    /// Build retention policy. Optional; defaults to the executor's
    /// default (50). Set explicitly to override on a per-pipeline
    /// basis.
    public let retention: Retention?
    /// Downstream job ids to enqueue when this build passes.
    /// Optional in YAML; defaults to empty. Each entry is a job id
    /// (the same shape returned by `POST /api/jobs`). Missing or
    /// terminally-misconfigured downstream jobs log a warning but do
    /// NOT fail the upstream build. Triggers fire ONLY when the
    /// upstream build's terminal status is `.passed`.
    public let triggers: [String]
    /// Required agent labels (Phase 18). When non-empty, the build is
    /// dispatched ONLY to a remote agent whose advertised labels
    /// (`SWIFTCI_AGENT_LABELS`) include EVERY string in this list. If
    /// no matching agent is currently idle the build waits in the
    /// queue rather than running in-process. When empty (the
    /// default), the build dispatches to any idle agent and falls
    /// back to in-process execution if none is connected — the
    /// pre-Phase-18 behaviour.
    public let agentLabels: [String]
    /// Phase 34: optional SCM source. When set, the executor clones
    /// the configured git repository into the build workspace at
    /// trigger time and reads pipeline steps from a Jenkinsfile (or
    /// other supported descriptor) inside the clone, replacing this
    /// `Pipeline`'s declared `steps` for that build only. The
    /// in-memory pipeline (and its `steps`, which may be empty when
    /// `scm` is set) remains the persisted source of truth on the
    /// controller; only the per-build effective step list is sourced
    /// from SCM.
    public let scm: SCMConfig?

    /// SCM source for pipeline-from-SCM builds (Phase 34).
    public struct SCMConfig: Codable, Hashable, Sendable {
        public let git: Git
        /// Workspace-relative path to the Jenkinsfile inside the
        /// clone. Defaults to `"Jenkinsfile"`.
        public let jenkinsfile: String

        public struct Git: Codable, Hashable, Sendable {
            /// Clone URL. Anything `git clone` accepts on the host:
            /// https://, git@, file://, or an absolute local path.
            public let url: String
            /// Branch / tag / commit to check out. Defaults to
            /// `"main"`. Passed to `git -c advice.detachedHead=false
            /// checkout <ref>` after the initial clone, so commit
            /// SHAs work as well as named refs.
            public let ref: String

            public init(url: String, ref: String = "main") {
                self.url = url
                self.ref = ref
            }

            private enum CodingKeys: String, CodingKey { case url, ref }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.url = try c.decode(String.self, forKey: .url)
                self.ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? "main"
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(url, forKey: .url)
                if ref != "main" { try c.encode(ref, forKey: .ref) }
            }
        }

        public init(git: Git, jenkinsfile: String = "Jenkinsfile") {
            self.git = git
            self.jenkinsfile = jenkinsfile
        }

        private enum CodingKeys: String, CodingKey { case git, jenkinsfile }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.git = try c.decode(Git.self, forKey: .git)
            self.jenkinsfile = try c.decodeIfPresent(String.self,
                forKey: .jenkinsfile) ?? "Jenkinsfile"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(git, forKey: .git)
            if jenkinsfile != "Jenkinsfile" {
                try c.encode(jenkinsfile, forKey: .jenkinsfile)
            }
        }
    }

    public struct Retention: Codable, Hashable, Sendable {
        /// Keep the last `maxBuilds` builds per job; older ones are
        /// pruned (status.json, log.txt, webhook.json, workspace,
        /// artifacts all removed). Must be > 0. `nil` means "use the
        /// executor's default" (currently 50).
        public let maxBuilds: Int?

        public init(maxBuilds: Int? = nil) {
            self.maxBuilds = maxBuilds
        }
    }

    public struct Notification: Codable, Hashable, Sendable {
        public enum When: String, Codable, Hashable, Sendable {
            case always, passed, failed
        }

        /// Absolute HTTP/HTTPS URL to POST to. Validated lexically only.
        public let url: String
        /// When to fire. Defaults to `.always`.
        public let on: When

        public init(url: String, on: When = .always) {
            self.url = url
            self.on = on
        }

        private enum CodingKeys: String, CodingKey { case url, on }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.url = try c.decode(String.self, forKey: .url)
            self.on  = try c.decodeIfPresent(When.self, forKey: .on) ?? .always
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(url, forKey: .url)
            if on != .always {
                try c.encode(on, forKey: .on)
            }
        }

        /// True if this notification should fire for `status`.
        public func shouldFire(for status: BuildStatus) -> Bool {
            switch on {
            case .always:
                return status.isTerminal
            case .passed:
                return status == .passed
            case .failed:
                // Treat .canceled as "not a clean pass" → fires.
                return status == .failed || status == .canceled
            }
        }
    }

    public struct Step: Codable, Hashable, Sendable {
        public let name: String
        /// Shell command to run. Empty when this step is a `parallel:`
        /// container (the branches define the work). When `parallel`
        /// is nil, `run` MUST be non-empty.
        public let run: String
        /// Per-step environment variables, merged on top of the parent
        /// process environment. Optional in YAML; defaults to empty.
        /// The executor layers its own `SWIFTCI_*` keys on top of this,
        /// so step env CANNOT shadow `SWIFTCI_JOB_ID` and friends.
        public let env: [String: String]
        /// Workspace-relative paths to collect as build artifacts after
        /// the step exits 0. Directories are copied recursively. Paths
        /// outside the workspace are rejected.
        public let artifacts: [String]
        /// Optional `when {}` gate (Phase 32). When non-nil and
        /// evaluating to false at execution time, the step is skipped
        /// — its `run:` is not invoked, the build log records the
        /// skip, and the build proceeds to the next step. A skipped
        /// step does NOT mark the build `.failed`.
        public let condition: StepCondition?
        /// Phase 36: declarative `parallel { … }` container. When
        /// non-nil, this step is a group: `run` is empty/ignored and
        /// the branches execute concurrently via a `TaskGroup`. Each
        /// branch's sub-steps run sequentially. The group succeeds
        /// when every branch's last sub-step exits 0; any failing
        /// branch fails the whole group (and the build). Nested
        /// `parallel:` inside a branch is rejected at decode time —
        /// swiftci v1 supports a single level of fan-out.
        public let parallel: [ParallelBranch]?
        /// Phase 37: declarative credential bindings. At build time
        /// the executor resolves each entry against the controller's
        /// `CredentialStore` and injects the secret value into the
        /// step's environment under `variable`. Missing ids fail the
        /// build with a clear error before the step's `run` is
        /// invoked. Defaults to empty.
        public let credentials: [CredentialBinding]

        public init(
            name: String,
            run: String,
            env: [String: String] = [:],
            artifacts: [String] = [],
            condition: StepCondition? = nil,
            parallel: [ParallelBranch]? = nil,
            credentials: [CredentialBinding] = []
        ) {
            self.name = name
            self.run = run
            self.env = env
            self.artifacts = artifacts
            self.condition = condition
            self.parallel = parallel
            self.credentials = credentials
        }

        // Custom Codable to make `env` + `artifacts` + `condition` +
        // `parallel` + `credentials` optional in the wire format.
        private enum CodingKeys: String, CodingKey {
            case name, run, env, artifacts, condition, parallel, credentials
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name      = try c.decode(String.self, forKey: .name)
            self.env       = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            self.artifacts = try c.decodeIfPresent([String].self, forKey: .artifacts) ?? []
            self.condition = try c.decodeIfPresent(StepCondition.self, forKey: .condition)
            self.parallel  = try c.decodeIfPresent([ParallelBranch].self, forKey: .parallel)
            self.credentials = try c.decodeIfPresent([CredentialBinding].self, forKey: .credentials) ?? []
            let runValue   = try c.decodeIfPresent(String.self, forKey: .run) ?? ""
            self.run = runValue
            // Exactly-one-of: a step is either a shell step (run set)
            // or a parallel group (parallel set), never both.
            if let parallel = self.parallel {
                if parallel.isEmpty {
                    throw DecodingError.dataCorruptedError(
                        forKey: .parallel, in: c,
                        debugDescription: "parallel: must have at least one branch")
                }
                if !runValue.isEmpty {
                    throw DecodingError.dataCorruptedError(
                        forKey: .run, in: c,
                        debugDescription: "step cannot set both `run:` and `parallel:`")
                }
                if !self.credentials.isEmpty {
                    throw DecodingError.dataCorruptedError(
                        forKey: .credentials, in: c,
                        debugDescription: "credentials: cannot be set on a parallel step — attach them to each branch's sub-step")
                }
            } else {
                if runValue.isEmpty {
                    throw DecodingError.dataCorruptedError(
                        forKey: .run, in: c,
                        debugDescription: "run: must be a non-empty command (or set parallel:)")
                }
            }
            // Validate credential bindings: id + variable must be
            // non-empty; variable must be a syntactically valid env
            // name (letters/digits/underscores, not starting with a
            // digit). Reject duplicate variable names to make
            // resolution deterministic.
            var seenVar: Set<String> = []
            for b in self.credentials {
                if b.credentialsId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw DecodingError.dataCorruptedError(
                        forKey: .credentials, in: c,
                        debugDescription: "credentialsId must be non-empty")
                }
                if !Self.isValidEnvName(b.variable) {
                    throw DecodingError.dataCorruptedError(
                        forKey: .credentials, in: c,
                        debugDescription: "variable '\(b.variable)' is not a valid environment variable name")
                }
                if !seenVar.insert(b.variable).inserted {
                    throw DecodingError.dataCorruptedError(
                        forKey: .credentials, in: c,
                        debugDescription: "duplicate credential variable: \(b.variable)")
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            if let parallel {
                try c.encode(parallel, forKey: .parallel)
            } else {
                try c.encode(run, forKey: .run)
            }
            if !env.isEmpty {
                try c.encode(env, forKey: .env)
            }
            if !artifacts.isEmpty {
                try c.encode(artifacts, forKey: .artifacts)
            }
            if let condition {
                try c.encode(condition, forKey: .condition)
            }
            if !credentials.isEmpty {
                try c.encode(credentials, forKey: .credentials)
            }
        }

        private static func isValidEnvName(_ s: String) -> Bool {
            guard let first = s.first else { return false }
            if !(first.isLetter || first == "_") { return false }
            for ch in s where !(ch.isLetter || ch.isNumber || ch == "_") {
                return false
            }
            return true
        }
    }

    /// Phase 37: one credential binding. Mirrors Jenkins's
    /// `string(credentialsId: 'X', variable: 'Y')` shape.
    public struct CredentialBinding: Codable, Hashable, Sendable {
        public let credentialsId: String
        public let variable: String

        public init(credentialsId: String, variable: String) {
            self.credentialsId = credentialsId
            self.variable = variable
        }
    }

    /// Phase 36: one branch of a `parallel:` group. Each branch has a
    /// human-readable `name` (used as a log prefix) and a sequential
    /// list of sub-steps that run inside the branch's own task.
    /// Nested `parallel:` is rejected — branches must be flat shell
    /// steps.
    public struct ParallelBranch: Codable, Hashable, Sendable {
        public let name: String
        public let steps: [Step]

        public init(name: String, steps: [Step]) {
            self.name = name
            self.steps = steps
        }

        private enum CodingKeys: String, CodingKey {
            case name, steps
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name  = try c.decode(String.self, forKey: .name)
            self.steps = try c.decode([Step].self, forKey: .steps)
            if self.steps.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .steps, in: c,
                    debugDescription: "parallel branch '\(self.name)' must have at least one step")
            }
            for s in self.steps where s.parallel != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .steps, in: c,
                    debugDescription: "nested parallel: inside branch '\(self.name)' is not supported")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(steps, forKey: .steps)
        }
    }

    /// Phase 32: declarative `when {}` gate translated from
    /// Jenkins's declarative pipeline language. Recursive so
    /// `not / allOf / anyOf` compose. Supported leaf predicates:
    ///
    ///   • `.branch(String)`    — Jenkins `branch 'X'`. Evaluates
    ///     against `env["BRANCH_NAME"]` (falls back to
    ///     `env["GIT_BRANCH"]`). `*` is a wildcard suffix.
    ///   • `.environment(name:value:)` — Jenkins
    ///     `environment name: 'X', value: 'Y'`. Evaluates against
    ///     the merged build env.
    ///   • `.not / .allOf / .anyOf` — composition.
    ///
    /// `expression { … }` is intentionally NOT modelled here —
    /// swiftci does not run Groovy. `JenkinsfileImporter` warns and
    /// drops `when { expression { … } }` rather than encoding it as
    /// a free-text predicate.
    public indirect enum StepCondition: Codable, Hashable, Sendable {
        case branch(String)
        case environment(name: String, value: String)
        case not(StepCondition)
        case allOf([StepCondition])
        case anyOf([StepCondition])

        /// Evaluate against a merged build env. `branch` reads
        /// `BRANCH_NAME` first, then `GIT_BRANCH` (a Jenkins
        /// convention).
        public func evaluate(env: [String: String]) -> Bool {
            switch self {
            case .branch(let pattern):
                let actual = env["BRANCH_NAME"] ?? env["GIT_BRANCH"] ?? ""
                return Self.matches(pattern: pattern, actual: actual)
            case .environment(let name, let want):
                return env[name] == want
            case .not(let inner):
                return !inner.evaluate(env: env)
            case .allOf(let xs):
                return xs.allSatisfy { $0.evaluate(env: env) }
            case .anyOf(let xs):
                return xs.contains { $0.evaluate(env: env) }
            }
        }

        /// Glob-lite matcher: `*` at the END of `pattern` matches any
        /// suffix. No other glob metacharacters. `feature/*` matches
        /// `feature/foo`. Exact otherwise.
        private static func matches(pattern: String, actual: String) -> Bool {
            if pattern.hasSuffix("*") {
                let prefix = pattern.dropLast()
                return actual.hasPrefix(prefix)
            }
            return pattern == actual
        }

        // MARK: - Codable
        //
        // Wire format (compact, future-extensible):
        //   { "branch": "main" }
        //   { "environment": { "name": "DEPLOY", "value": "yes" } }
        //   { "not": <Condition> }
        //   { "allOf": [<Condition>, ...] }
        //   { "anyOf": [<Condition>, ...] }
        private enum CodingKeys: String, CodingKey {
            case branch, environment, not, allOf, anyOf
        }
        private struct EnvPair: Codable, Hashable, Sendable {
            let name: String
            let value: String
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try c.decodeIfPresent(String.self, forKey: .branch) {
                self = .branch(s); return
            }
            if let p = try c.decodeIfPresent(EnvPair.self, forKey: .environment) {
                self = .environment(name: p.name, value: p.value); return
            }
            if let inner = try c.decodeIfPresent(StepCondition.self, forKey: .not) {
                self = .not(inner); return
            }
            if let xs = try c.decodeIfPresent([StepCondition].self, forKey: .allOf) {
                self = .allOf(xs); return
            }
            if let xs = try c.decodeIfPresent([StepCondition].self, forKey: .anyOf) {
                self = .anyOf(xs); return
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "no recognised StepCondition variant"))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .branch(let s):
                try c.encode(s, forKey: .branch)
            case .environment(let n, let v):
                try c.encode(EnvPair(name: n, value: v), forKey: .environment)
            case .not(let inner):
                try c.encode(inner, forKey: .not)
            case .allOf(let xs):
                try c.encode(xs, forKey: .allOf)
            case .anyOf(let xs):
                try c.encode(xs, forKey: .anyOf)
            }
        }
    }

    public init(
        name: String,
        steps: [Step],
        notify: [Notification] = [],
        retention: Retention? = nil,
        triggers: [String] = [],
        agentLabels: [String] = [],
        scm: SCMConfig? = nil
    ) {
        self.name = name
        self.steps = steps
        self.notify = notify
        self.retention = retention
        self.triggers = triggers
        self.agentLabels = agentLabels
        self.scm = scm
    }

    /// Decode a `Pipeline` from a YAML source string.
    /// Throws `PipelineError.empty` if the source is whitespace-only.
    public static func decode(yaml source: String) throws -> Pipeline {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PipelineError.empty }
        return try YAMLDecoder().decode(Pipeline.self, from: source)
    }

    /// Encode this pipeline back to a YAML string. Round-trips through
    /// `Yams.YAMLEncoder` so output is canonical (sorted keys disabled —
    /// `Codable` preserves declaration order).
    public func encodeYAML() throws -> String {
        try YAMLEncoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case name, steps, notify, retention, triggers, agentLabels, scm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name      = try c.decode(String.self, forKey: .name)
        // Phase 34: `steps` is optional in YAML when `scm:` is set,
        // since the effective step list is sourced from the cloned
        // Jenkinsfile at build time. Without `scm:` we still require
        // a non-empty `steps` array (validated below).
        self.scm       = try c.decodeIfPresent(SCMConfig.self, forKey: .scm)
        self.steps     = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        self.notify    = try c.decodeIfPresent([Notification].self, forKey: .notify) ?? []
        self.retention = try c.decodeIfPresent(Retention.self, forKey: .retention)
        self.triggers  = try c.decodeIfPresent([String].self, forKey: .triggers) ?? []
        self.agentLabels = try c.decodeIfPresent([String].self, forKey: .agentLabels) ?? []
        if self.scm == nil && self.steps.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .steps, in: c,
                debugDescription: "steps must be a non-empty array when `scm:` is not set")
        }
        if self.scm != nil && !self.agentLabels.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .agentLabels, in: c,
                debugDescription: "`scm:` pipelines run in-process on the controller; remove `agentLabels:`")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        // Always emit `steps` to keep YAML round-trip stable, even when
        // empty under `scm:` (an empty list reads cleanly back).
        try c.encode(steps, forKey: .steps)
        if !notify.isEmpty {
            try c.encode(notify, forKey: .notify)
        }
        if let retention {
            try c.encode(retention, forKey: .retention)
        }
        if !triggers.isEmpty {
            try c.encode(triggers, forKey: .triggers)
        }
        if !agentLabels.isEmpty {
            try c.encode(agentLabels, forKey: .agentLabels)
        }
        if let scm {
            try c.encode(scm, forKey: .scm)
        }
    }
}

public enum PipelineError: Error, Equatable, Sendable {
    case empty
}
