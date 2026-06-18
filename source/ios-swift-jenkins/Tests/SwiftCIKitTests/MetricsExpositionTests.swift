import Foundation
import Testing
@testable import SwiftCIKit

@Suite("MetricsExposition")
struct MetricsExpositionTests {
    @Test("emits every required metric family")
    func emitsAllFamilies() {
        let s = MetricsExposition.Snapshot(
            version: "0.1.0-alpha",
            queueDepth: 2,
            jobs: 5,
            agentsIdle: 1,
            agentsBusy: 1,
            agentsDisconnected: 0,
            buildsByStatus: ["passed": 10, "failed": 3]
        )
        let out = MetricsExposition.render(s)

        // # HELP / # TYPE banners for each family
        for family in [
            "swiftci_up", "swiftci_version_info",
            "swiftci_jobs", "swiftci_queue_depth",
            "swiftci_agents", "swiftci_builds",
        ] {
            #expect(out.contains("# HELP \(family) "),
                    "missing HELP for \(family)\nfull body:\n\(out)")
            #expect(out.contains("# TYPE \(family) gauge"),
                    "missing TYPE for \(family)")
        }
    }

    @Test("renders gauge values verbatim")
    func gaugeValues() {
        let s = MetricsExposition.Snapshot(
            version: "9.9.9",
            queueDepth: 7,
            jobs: 4,
            agentsIdle: 2,
            agentsBusy: 1,
            agentsDisconnected: 3,
            buildsByStatus: [
                "passed": 12, "failed": 4, "canceled": 1, "running": 0,
            ]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("swiftci_up 1\n"))
        #expect(out.contains("swiftci_jobs 4\n"))
        #expect(out.contains("swiftci_queue_depth 7\n"))
        #expect(out.contains("swiftci_agents{state=\"idle\"} 2\n"))
        #expect(out.contains("swiftci_agents{state=\"busy\"} 1\n"))
        #expect(out.contains("swiftci_agents{state=\"disconnected\"} 3\n"))
        #expect(out.contains("swiftci_builds{status=\"passed\"} 12\n"))
        #expect(out.contains("swiftci_builds{status=\"failed\"} 4\n"))
        #expect(out.contains("swiftci_builds{status=\"canceled\"} 1\n"))
    }

    @Test("emits zero for missing build statuses so the label set stays stable")
    func missingStatusesAsZero() {
        let s = MetricsExposition.Snapshot(
            version: "0.0.0",
            queueDepth: 0,
            jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        for status in ["queued", "running", "passed", "failed", "canceled"] {
            #expect(out.contains("swiftci_builds{status=\"\(status)\"} 0\n"),
                    "missing zero entry for status=\(status)\nfull body:\n\(out)")
        }
    }

    @Test("escapes special characters in version label")
    func escapesVersionLabel() {
        let s = MetricsExposition.Snapshot(
            version: "v1.\"2\"\\3",
            queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains(#"swiftci_version_info{version="v1.\"2\"\\3"} 1"#),
                "version escaping wrong:\n\(out)")
    }

    @Test("body ends with newline as required by exposition format")
    func endsWithNewline() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        #expect(MetricsExposition.render(s).hasSuffix("\n"))
    }

    // ── Phase 20: build-duration histogram ────────────────────────

    @Test("histogram emits stable label set even when no terminal builds exist")
    func histogramEmptyLabelSet() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_build_duration_seconds histogram"))
        for status in ["passed", "failed", "canceled"] {
            // Every bucket boundary must appear with count 0.
            for le in ["1", "5", "10", "30", "60", "300", "600", "1800", "3600", "+Inf"] {
                #expect(out.contains(
                    "swiftci_build_duration_seconds_bucket{status=\"\(status)\",le=\"\(le)\"} 0\n"),
                    "missing zero bucket status=\(status) le=\(le)\nbody:\n\(out)")
            }
            #expect(out.contains("swiftci_build_duration_seconds_sum{status=\"\(status)\"} 0\n"))
            #expect(out.contains("swiftci_build_duration_seconds_count{status=\"\(status)\"} 0\n"))
        }
    }

    @Test("histogram bucket counts are cumulative")
    func histogramCumulative() {
        // Three passed builds at 0.5s, 7s, 90s. Expected cumulative
        // counts: le=1 → 1, le=5 → 1, le=10 → 2, le=30 → 2, le=60 → 2,
        // le=300 → 3, le=+Inf → 3.
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            durationsByStatus: ["passed": [0.5, 7, 90]]
        )
        let out = MetricsExposition.render(s)
        let expectations: [(String, Int)] = [
            ("1", 1), ("5", 1), ("10", 2), ("30", 2), ("60", 2),
            ("300", 3), ("600", 3), ("1800", 3), ("3600", 3), ("+Inf", 3),
        ]
        for (le, n) in expectations {
            #expect(out.contains(
                "swiftci_build_duration_seconds_bucket{status=\"passed\",le=\"\(le)\"} \(n)\n"),
                "wrong cumulative count for le=\(le); expected \(n)\nbody:\n\(out)")
        }
        #expect(out.contains("swiftci_build_duration_seconds_count{status=\"passed\"} 3\n"))
        // sum = 0.5 + 7 + 90 = 97.5
        #expect(out.contains("swiftci_build_duration_seconds_sum{status=\"passed\"} 97.5\n"),
                "sum line missing or wrong:\n\(out)")
    }

    @Test("histogram per-status independence")
    func histogramPerStatus() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            durationsByStatus: [
                "passed":   [3, 4],
                "failed":   [120],
                "canceled": [],
            ]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("swiftci_build_duration_seconds_count{status=\"passed\"} 2\n"))
        #expect(out.contains("swiftci_build_duration_seconds_count{status=\"failed\"} 1\n"))
        #expect(out.contains("swiftci_build_duration_seconds_count{status=\"canceled\"} 0\n"))
        #expect(out.contains("swiftci_build_duration_seconds_bucket{status=\"failed\",le=\"60\"} 0\n"))
        #expect(out.contains("swiftci_build_duration_seconds_bucket{status=\"failed\",le=\"300\"} 1\n"))
    }

    // ── Phase 21: queue-wait histogram ────────────────────────────

    @Test("queue-wait histogram emits stable label set when empty")
    func queueWaitEmpty() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_build_queue_wait_seconds histogram"))
        for le in ["0.1", "0.5", "1", "5", "10", "30", "60", "300", "900", "+Inf"] {
            #expect(out.contains("swiftci_build_queue_wait_seconds_bucket{le=\"\(le)\"} 0\n"),
                    "missing zero bucket le=\(le)\nbody:\n\(out)")
        }
        #expect(out.contains("swiftci_build_queue_wait_seconds_sum 0\n"))
        #expect(out.contains("swiftci_build_queue_wait_seconds_count 0\n"))
    }

    @Test("queue-wait histogram bucket counts are cumulative")
    func queueWaitCumulative() {
        // Waits chosen as exactly-representable doubles so the
        // sum prints deterministically across platforms.
        // 0.125 + 2 + 45 + 700 = 747.125. Cumulative bucket counts:
        // le=0.1 → 0, le=0.5 → 1, le=1 → 1, le=5 → 2, le=10 → 2,
        // le=30 → 2, le=60 → 3, le=300 → 3, le=900 → 4, +Inf → 4.
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            queueWaitsSeconds: [0.125, 2, 45, 700]
        )
        let out = MetricsExposition.render(s)
        let expectations: [(String, Int)] = [
            ("0.1", 0), ("0.5", 1), ("1", 1), ("5", 2), ("10", 2),
            ("30", 2), ("60", 3), ("300", 3), ("900", 4), ("+Inf", 4),
        ]
        for (le, n) in expectations {
            #expect(out.contains("swiftci_build_queue_wait_seconds_bucket{le=\"\(le)\"} \(n)\n"),
                    "wrong cumulative count for le=\(le); expected \(n)\nbody:\n\(out)")
        }
        #expect(out.contains("swiftci_build_queue_wait_seconds_count 4\n"))
        #expect(out.contains("swiftci_build_queue_wait_seconds_sum 747.125\n"),
                "sum line missing or wrong:\n\(out)")
    }

    // ── Phase 22: oldest-queued-age gauge ─────────────────────────

    @Test("oldest-queued-age gauge defaults to 0 when queue empty")
    func oldestAgeEmpty() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_queue_oldest_age_seconds gauge"))
        #expect(out.contains("swiftci_queue_oldest_age_seconds 0\n"))
    }

    @Test("oldest-queued-age gauge renders provided value")
    func oldestAgeRenders() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 2, jobs: 1,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            queueOldestAgeSeconds: 17.5
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("swiftci_queue_oldest_age_seconds 17.5\n"))
    }

    // ── Phase 23: per-job last-build info gauge ───────────────────

    @Test("last-build info gauge emits TYPE line even when empty")
    func lastBuildEmpty() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_job_last_build_info gauge"))
        // No series rendered for jobs with no terminal builds yet.
        #expect(!out.contains("swiftci_job_last_build_info{"))
    }

    @Test("last-build info gauge renders one series per job with labels and timestamp value")
    func lastBuildRenders() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 2,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            lastBuildByJob: [
                "alpha": .init(number: 7, status: "passed",
                               endedAtUnixSeconds: 1_700_000_010),
                "beta":  .init(number: 3, status: "failed",
                               endedAtUnixSeconds: 1_700_000_500),
            ]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains(
            "swiftci_job_last_build_info{job=\"alpha\",status=\"passed\",number=\"7\"} 1700000010\n"))
        #expect(out.contains(
            "swiftci_job_last_build_info{job=\"beta\",status=\"failed\",number=\"3\"} 1700000500\n"))
    }

    @Test("last-build info gauge emits series in sorted job-id order for byte stability")
    func lastBuildSorted() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 3,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            lastBuildByJob: [
                "zeta":   .init(number: 1, status: "passed", endedAtUnixSeconds: 1),
                "alpha":  .init(number: 1, status: "passed", endedAtUnixSeconds: 2),
                "middle": .init(number: 1, status: "passed", endedAtUnixSeconds: 3),
            ]
        )
        let out = MetricsExposition.render(s)
        guard let a = out.range(of: "job=\"alpha\""),
              let m = out.range(of: "job=\"middle\""),
              let z = out.range(of: "job=\"zeta\"") else {
            Issue.record("expected all three job series in body:\n\(out)")
            return
        }
        #expect(a.lowerBound < m.lowerBound)
        #expect(m.lowerBound < z.lowerBound)
    }

    @Test("last-build info escapes special characters in job IDs")
    func lastBuildEscapes() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 1,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            lastBuildByJob: [
                "weird\"name\\here": .init(number: 1, status: "passed",
                                            endedAtUnixSeconds: 1),
            ]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains(
            "swiftci_job_last_build_info{job=\"weird\\\"name\\\\here\",status=\"passed\",number=\"1\"} 1\n"))
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 25: per-job last-build duration gauge.
    // ──────────────────────────────────────────────────────────────

    @Test("last-build duration gauge emits TYPE line even when empty")
    func lastBuildDurationEmpty() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_job_last_build_duration_seconds gauge\n"))
        #expect(!out.contains("swiftci_job_last_build_duration_seconds{"))
    }

    @Test("last-build duration gauge renders series when duration present")
    func lastBuildDurationRenders() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 1,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            lastBuildByJob: [
                "job-a": .init(number: 7, status: "passed",
                               endedAtUnixSeconds: 1_700_000_000,
                               durationSeconds: 42.5),
            ]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains(
            "swiftci_job_last_build_duration_seconds{job=\"job-a\",status=\"passed\",number=\"7\"} 42.5\n"))
    }

    @Test("last-build duration omitted when nil (older persisted record)")
    func lastBuildDurationOmittedWhenNil() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 1,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            lastBuildByJob: [
                "job-a": .init(number: 3, status: "passed",
                               endedAtUnixSeconds: 1_700_000_000,
                               durationSeconds: nil),
            ]
        )
        let out = MetricsExposition.render(s)
        // info gauge still present
        #expect(out.contains("swiftci_job_last_build_info{job=\"job-a\""))
        // duration series deliberately absent
        #expect(!out.contains("swiftci_job_last_build_duration_seconds{job=\"job-a\""))
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 26: process start time gauge.
    // ──────────────────────────────────────────────────────────────

    @Test("process start time gauge always rendered with TYPE line")
    func processStartTimeRenders() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            processStartTimeUnixSeconds: 1_700_000_000
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_process_start_time_seconds gauge\n"))
        #expect(out.contains("swiftci_process_start_time_seconds 1700000000\n"))
    }

    @Test("process start time defaults to 0 when not supplied")
    func processStartTimeDefaultsToZero() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("swiftci_process_start_time_seconds 0\n"))
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 27: per-job build counts gauge.
    // ──────────────────────────────────────────────────────────────

    @Test("per-job builds gauge emits TYPE line even when empty")
    func jobBuildsEmpty() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 0,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:]
        )
        let out = MetricsExposition.render(s)
        #expect(out.contains("# TYPE swiftci_job_builds gauge\n"))
        #expect(!out.contains("swiftci_job_builds{"))
    }

    @Test("per-job builds gauge emits stable status label set per job")
    func jobBuildsStableLabelSet() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 1,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            jobBuildsByStatus: [
                "job-a": ["passed": 3, "failed": 1],
            ]
        )
        let out = MetricsExposition.render(s)
        for status in ["queued", "running", "passed", "failed", "canceled"] {
            #expect(out.contains("swiftci_job_builds{job=\"job-a\",status=\"\(status)\"}"))
        }
        #expect(out.contains("swiftci_job_builds{job=\"job-a\",status=\"passed\"} 3\n"))
        #expect(out.contains("swiftci_job_builds{job=\"job-a\",status=\"failed\"} 1\n"))
        #expect(out.contains("swiftci_job_builds{job=\"job-a\",status=\"queued\"} 0\n"))
    }

    @Test("per-job builds gauge emits jobs in sorted order for byte stability")
    func jobBuildsSortedOrder() {
        let s = MetricsExposition.Snapshot(
            version: "0", queueDepth: 0, jobs: 2,
            agentsIdle: 0, agentsBusy: 0, agentsDisconnected: 0,
            buildsByStatus: [:],
            jobBuildsByStatus: [
                "zeta":  ["passed": 1],
                "alpha": ["passed": 2],
            ]
        )
        let out = MetricsExposition.render(s)
        guard
            let aRange = out.range(of: "swiftci_job_builds{job=\"alpha\""),
            let zRange = out.range(of: "swiftci_job_builds{job=\"zeta\"")
        else {
            Issue.record("missing expected per-job series")
            return
        }
        #expect(aRange.lowerBound < zRange.lowerBound)
    }
}
