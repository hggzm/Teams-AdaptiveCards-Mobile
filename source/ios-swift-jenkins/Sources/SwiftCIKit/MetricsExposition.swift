import Foundation

/// Phase 19: Prometheus text exposition for the `/metrics` endpoint.
///
/// We deliberately stay format-only (text exposition format 0.0.4)
/// rather than pulling in a full client library. The `/metrics`
/// route aggregates state from the executor + registry + store and
/// hands it to `render(_:)` which produces a UTF-8 body suitable for
/// any Prometheus-compatible scraper (Prometheus, VictoriaMetrics,
/// Grafana Agent, OpenTelemetry Collector, …).
///
/// All metrics are reported as `gauge`s so the scraper can compute
/// rates / deltas itself; we avoid the bookkeeping needed for proper
/// counters that survive process restarts. The `swiftci_builds`
/// gauge below reflects the on-disk build count by status — perfectly
/// adequate for "how many failures today" panels because the
/// retention policy bounds the on-disk window.
public enum MetricsExposition {
    /// Snapshot of all numbers exposed at `/metrics`. Built by the
    /// route handler from the executor + registry + store, then
    /// passed to `render(_:)`.
    public struct Snapshot: Equatable, Sendable {
        public var version: String
        public var queueDepth: Int
        public var jobs: Int
        /// Connected, not currently running a build.
        public var agentsIdle: Int
        /// Connected, currently running a build.
        public var agentsBusy: Int
        /// WebSocket has closed but the registry still holds the
        /// record (cleared lazily).
        public var agentsDisconnected: Int
        /// On-disk build counts keyed by `BuildStatus.rawValue`.
        /// Missing keys render as 0.
        public var buildsByStatus: [String: Int]
        /// Phase 20: durations (seconds) of every persisted build whose
        /// `startedAt` and `endedAt` are both set, grouped by terminal
        /// status (`passed` / `failed` / `canceled`). Used to render
        /// the `swiftci_build_duration_seconds` histogram.
        public var durationsByStatus: [String: [Double]]
        /// Phase 21: queue-wait times (seconds) of every persisted
        /// build whose `queuedAt` and `startedAt` are both set. Single
        /// pooled series — there is no useful `status` axis since the
        /// build is still `.queued` while waiting. Empty for builds
        /// that never started (still queued, or persisted by an older
        /// controller version that didn't record `queuedAt`).
        public var queueWaitsSeconds: [Double]
        /// Phase 22: age (seconds) of the oldest build currently
        /// waiting in the executor queue, or `0` when the queue is
        /// empty. Distinct from `queueWaitsSeconds` (which is a
        /// histogram of completed waits) — this gauge is what alerts
        /// fire on ("a build has been queued for more than N seconds").
        public var queueOldestAgeSeconds: Double
        /// Phase 23: most recent terminal build per job. Keys are job
        /// IDs; values describe the build that should drive the
        /// dashboard "last build" stat panel and freshness alerts.
        /// Jobs that have never produced a terminal build are simply
        /// absent from this map (no info series emitted, no zero
        /// gauges) — a freshness alert should treat "series missing"
        /// the same as "too old".
        public var lastBuildByJob: [String: LastBuildInfo]

        /// Phase 26: unix-seconds timestamp at which the controller
        /// process started. Exposed as the standard
        /// `swiftci_process_start_time_seconds` gauge; scrapers
        /// derive uptime as `time() - that_value`. Defaults to 0 in
        /// snapshots that don't supply it (older callers stay
        /// compiling, the gauge then renders 0 and dashboards treat
        /// it as "unknown / pre-Phase-26").
        public var processStartTimeUnixSeconds: Double

        /// Phase 27: per-job build counts bucketed by status. Outer
        /// key is job id; inner key is status raw value. Renders as
        /// `swiftci_job_builds{job="X",status="passed"} N`. Defaults
        /// to empty so older callers compile and emit only the TYPE
        /// line.
        public var jobBuildsByStatus: [String: [String: Int]]

        /// Snapshot of a job's most recent terminal build for the
        /// info-style gauge. Value emitted on the wire is
        /// `endedAtUnixSeconds` (so Grafana can both render the
        /// labelled status AND age-since-last-build from one series).
        public struct LastBuildInfo: Equatable, Sendable {
            public var number: Int
            public var status: String
            public var endedAtUnixSeconds: Double
            /// Phase 25: wall-clock duration in seconds of this
            /// last terminal build. `nil` when the persisted build
            /// is missing one of `startedAt` / `endedAt` (older
            /// records pre-Phase-21). Rendered as a separate gauge
            /// `swiftci_job_last_build_duration_seconds{job="X"}`
            /// so dashboards can chart "how long is the most recent
            /// build of each job taking" without scraping per-build
            /// history.
            public var durationSeconds: Double?

            public init(number: Int, status: String, endedAtUnixSeconds: Double, durationSeconds: Double? = nil) {
                self.number = number
                self.status = status
                self.endedAtUnixSeconds = endedAtUnixSeconds
                self.durationSeconds = durationSeconds
            }
        }

        public init(
            version: String,
            queueDepth: Int,
            jobs: Int,
            agentsIdle: Int,
            agentsBusy: Int,
            agentsDisconnected: Int,
            buildsByStatus: [String: Int],
            durationsByStatus: [String: [Double]] = [:],
            queueWaitsSeconds: [Double] = [],
            queueOldestAgeSeconds: Double = 0,
            lastBuildByJob: [String: LastBuildInfo] = [:],
            processStartTimeUnixSeconds: Double = 0,
            jobBuildsByStatus: [String: [String: Int]] = [:]
        ) {
            self.version = version
            self.queueDepth = queueDepth
            self.jobs = jobs
            self.agentsIdle = agentsIdle
            self.agentsBusy = agentsBusy
            self.agentsDisconnected = agentsDisconnected
            self.buildsByStatus = buildsByStatus
            self.durationsByStatus = durationsByStatus
            self.queueWaitsSeconds = queueWaitsSeconds
            self.queueOldestAgeSeconds = queueOldestAgeSeconds
            self.lastBuildByJob = lastBuildByJob
            self.processStartTimeUnixSeconds = processStartTimeUnixSeconds
            self.jobBuildsByStatus = jobBuildsByStatus
        }
    }

    /// Phase 20: histogram bucket upper bounds (seconds), tuned for
    /// CI build durations from sub-second smoke runs through long
    /// integration suites. The trailing `+Inf` bucket is always
    /// emitted by the renderer.
    public static let durationBucketsSeconds: [Double] = [
        1, 5, 10, 30, 60, 300, 600, 1800, 3600,
    ]

    /// Phase 21: histogram bucket upper bounds (seconds) for queue
    /// wait time. Tighter low end than the build-duration buckets
    /// because operators care about sub-second responsiveness, but
    /// shorter long tail (a build that's been queued for an hour
    /// is already a problem).
    public static let queueWaitBucketsSeconds: [Double] = [
        0.1, 0.5, 1, 5, 10, 30, 60, 300, 900,
    ]

    /// The Prometheus text content type, including the version
    /// hint scrapers look for.
    public static let contentType = "text/plain; version=0.0.4; charset=utf-8"

    /// Render `snapshot` as a Prometheus exposition payload. The
    /// output ends with a trailing newline as required by the spec.
    public static func render(_ s: Snapshot) -> String {
        var out = ""

        out += "# HELP swiftci_up 1 if the controller is healthy\n"
        out += "# TYPE swiftci_up gauge\n"
        out += "swiftci_up 1\n"

        out += "# HELP swiftci_version_info Static info about the running controller\n"
        out += "# TYPE swiftci_version_info gauge\n"
        out += "swiftci_version_info{version=\"\(escape(s.version))\"} 1\n"

        // Phase 26: standard-shape process start time gauge.
        out += "# HELP swiftci_process_start_time_seconds Unix-seconds timestamp at which the controller process started\n"
        out += "# TYPE swiftci_process_start_time_seconds gauge\n"
        out += "swiftci_process_start_time_seconds \(formatFloat(s.processStartTimeUnixSeconds))\n"

        out += "# HELP swiftci_jobs Number of registered pipelines\n"
        out += "# TYPE swiftci_jobs gauge\n"
        out += "swiftci_jobs \(s.jobs)\n"

        out += "# HELP swiftci_queue_depth Builds waiting in the executor queue\n"
        out += "# TYPE swiftci_queue_depth gauge\n"
        out += "swiftci_queue_depth \(s.queueDepth)\n"

        // Phase 22: age of the oldest queued build (head of the
        // FIFO). 0 when the queue is empty. Pair with
        // swiftci_queue_depth in alerts: "depth > 0 AND oldest_age >
        // 5m" is the canonical "the executor is stuck" condition.
        out += "# HELP swiftci_queue_oldest_age_seconds Age in seconds of the oldest build currently waiting in the queue (0 if empty)\n"
        out += "# TYPE swiftci_queue_oldest_age_seconds gauge\n"
        out += "swiftci_queue_oldest_age_seconds \(formatFloat(s.queueOldestAgeSeconds))\n"

        out += "# HELP swiftci_agents Number of registered agents by state\n"
        out += "# TYPE swiftci_agents gauge\n"
        out += "swiftci_agents{state=\"idle\"} \(s.agentsIdle)\n"
        out += "swiftci_agents{state=\"busy\"} \(s.agentsBusy)\n"
        out += "swiftci_agents{state=\"disconnected\"} \(s.agentsDisconnected)\n"

        out += "# HELP swiftci_builds Number of persisted builds by status\n"
        out += "# TYPE swiftci_builds gauge\n"
        // Always emit every status so the scraper sees a stable label
        // set even when no builds in that bucket exist yet.
        for status in ["queued", "running", "passed", "failed", "canceled"] {
            let n = s.buildsByStatus[status] ?? 0
            out += "swiftci_builds{status=\"\(status)\"} \(n)\n"
        }

        // ── Phase 20: build duration histogram per terminal status.
        // We always emit all three terminal buckets so the label set
        // is stable from the very first scrape (Grafana variables
        // depend on label discovery).
        out += "# HELP swiftci_build_duration_seconds Wall-clock build duration in seconds, by terminal status\n"
        out += "# TYPE swiftci_build_duration_seconds histogram\n"
        for status in ["passed", "failed", "canceled"] {
            let samples = s.durationsByStatus[status] ?? []
            // Cumulative bucket counts: a sample falls in every bucket
            // whose `le` is >= its value. Prometheus requires the
            // counts to be monotonically non-decreasing as `le` grows.
            for upper in durationBucketsSeconds {
                let count = samples.lazy.filter { $0 <= upper }.count
                out += "swiftci_build_duration_seconds_bucket{status=\"\(status)\",le=\"\(formatBucket(upper))\"} \(count)\n"
            }
            out += "swiftci_build_duration_seconds_bucket{status=\"\(status)\",le=\"+Inf\"} \(samples.count)\n"
            let sum = samples.reduce(0, +)
            out += "swiftci_build_duration_seconds_sum{status=\"\(status)\"} \(formatFloat(sum))\n"
            out += "swiftci_build_duration_seconds_count{status=\"\(status)\"} \(samples.count)\n"
        }

        // ── Phase 21: queue-wait histogram (single pooled series).
        out += "# HELP swiftci_build_queue_wait_seconds Wall-clock seconds builds spent waiting in the executor queue\n"
        out += "# TYPE swiftci_build_queue_wait_seconds histogram\n"
        let waits = s.queueWaitsSeconds
        for upper in queueWaitBucketsSeconds {
            let count = waits.lazy.filter { $0 <= upper }.count
            out += "swiftci_build_queue_wait_seconds_bucket{le=\"\(formatBucket(upper))\"} \(count)\n"
        }
        out += "swiftci_build_queue_wait_seconds_bucket{le=\"+Inf\"} \(waits.count)\n"
        let waitSum = waits.reduce(0, +)
        out += "swiftci_build_queue_wait_seconds_sum \(formatFloat(waitSum))\n"
        out += "swiftci_build_queue_wait_seconds_count \(waits.count)\n"

        // ── Phase 23: per-job last-build info-style gauge. Value is
        // the unix-seconds endedAt timestamp of the most recent
        // terminal build, so a single series drives both "what was
        // the last status?" (label) AND "how long since last build?"
        // (time() - value) in Grafana / alerting rules. Jobs with no
        // terminal builds yet are deliberately absent — a freshness
        // alert handles "series missing" the same as "too old".
        // Iterate the keys in sorted order so the body is byte-stable
        // across scrapes (helps diff-based change-detection tooling).
        out += "# HELP swiftci_job_last_build_info Most recent terminal build per job; value is unix-seconds of endedAt\n"
        out += "# TYPE swiftci_job_last_build_info gauge\n"
        for job in s.lastBuildByJob.keys.sorted() {
            guard let info = s.lastBuildByJob[job] else { continue }
            out += "swiftci_job_last_build_info{job=\"\(escape(job))\",status=\"\(escape(info.status))\",number=\"\(info.number)\"} \(formatFloat(info.endedAtUnixSeconds))\n"
        }

        // ── Phase 25: per-job last-build duration gauge. Only
        // emitted for jobs whose persisted last terminal build
        // carried both `startedAt` and `endedAt` (the same
        // condition as the duration histogram in Phase 20). Jobs
        // with no terminal builds and pre-Phase-21 records with a
        // missing timestamp are deliberately absent rather than
        // reported as 0 — a missing series is unambiguous, a 0
        // would look like "the last build took 0 seconds".
        out += "# HELP swiftci_job_last_build_duration_seconds Wall-clock duration in seconds of the most recent terminal build per job\n"
        out += "# TYPE swiftci_job_last_build_duration_seconds gauge\n"
        for job in s.lastBuildByJob.keys.sorted() {
            guard let info = s.lastBuildByJob[job], let d = info.durationSeconds else { continue }
            out += "swiftci_job_last_build_duration_seconds{job=\"\(escape(job))\",status=\"\(escape(info.status))\",number=\"\(info.number)\"} \(formatFloat(d))\n"
        }

        // ── Phase 27: per-job build counts by status. Emits one
        // series per (job, status) pair with a stable status label
        // set so dashboards can build per-pipeline pass-rate panels
        // without dynamic discovery. Jobs with zero builds in a
        // given status still emit `... 0` to keep the label set
        // stable. Iterates jobs in sorted order for byte-stable
        // output across scrapes.
        out += "# HELP swiftci_job_builds Number of persisted builds per job, bucketed by status\n"
        out += "# TYPE swiftci_job_builds gauge\n"
        for job in s.jobBuildsByStatus.keys.sorted() {
            let perStatus = s.jobBuildsByStatus[job] ?? [:]
            for status in ["queued", "running", "passed", "failed", "canceled"] {
                let n = perStatus[status] ?? 0
                out += "swiftci_job_builds{job=\"\(escape(job))\",status=\"\(status)\"} \(n)\n"
            }
        }

        return out
    }

    /// Format a bucket boundary the way Prometheus expects: integers
    /// stay integer-shaped (`60` not `60.0`); fractional values keep
    /// their decimal form.
    private static func formatBucket(_ v: Double) -> String {
        if v.rounded() == v { return String(Int(v)) }
        return String(v)
    }

    /// Format a floating-point sum compactly. Prometheus is happy with
    /// either `12` or `12.345`; we trim a trailing `.0` to keep the
    /// output stable across platforms.
    private static func formatFloat(_ v: Double) -> String {
        if v.rounded() == v { return String(Int(v)) }
        return String(v)
    }


    /// Escape a label value per the Prometheus exposition spec
    /// (backslash, double-quote, newline).
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default:   out.append(ch)
            }
        }
        return out
    }
}
