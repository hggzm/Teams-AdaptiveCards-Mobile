// AdaptiveCardsDemo — Flavor A runtime symbol-check.
//
// Drives the vendored swiftharness kit through a real
// store-and-retrieve round-trip of the canonical AdaptiveCards.io
// "Hello World" sample card. Symbols exercised (≥3 required):
//
//   1.  SessionStore(root:)                — Sources/SwiftHarnessSession/SessionStore.swift
//   2.  SessionStore.createSession()       — same file
//   3.  SessionStore.appendTurn(_:prompt:) — same file
//   4.  SessionStore.loadTranscript(_:)    — same file
//   5.  TranscriptRecord.find(query:)      — Sources/SwiftHarnessSession/TranscriptInspection.swift
//   6.  Prompt(_:)                         — Sources/SwiftHarnessCore/Names.swift
//
// Outcome: PASS adaptivecards-swiftharness-roundtrip on stdout when
// the AdaptiveCard JSON bytes survive a round trip through the
// on-disk store and the inspection verb finds them back.

import Foundation
import SwiftHarnessCore
import SwiftHarnessSession

@main
struct AdaptiveCardsDemo {
    static func main() async throws {
        // Use a temporary .sessions/ root so the demo leaves nothing
        // behind on the host between runs.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "adaptivecards-swiftharness-demo-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)

        // 1. Create a fresh session.
        let session = try await store.createSession()

        // 2. Persist the canonical AdaptiveCard JSON as turn 0.
        _ = try await store.appendTurn(
            session.sessionId,
            prompt: Prompt(SampleCard.helloWorldJSON)
        )

        // 3. Read the transcript back from disk and confirm the
        //    AdaptiveCard payload survived bytewise.
        let transcript = try await store.loadTranscript(session.sessionId)
        guard transcript.entries.count == 1 else {
            fatalError("expected 1 transcript entry, got \(transcript.entries.count)")
        }
        let recovered = transcript.entries[0].prompt.asString
        guard recovered == SampleCard.helloWorldJSON else {
            fatalError("recovered prompt did not match original AdaptiveCard JSON")
        }

        // 4. Use the inspection-verb surface to confirm the card is
        //    findable by content.
        let hits = transcript.find(query: "AdaptiveCard")
        guard hits.count == 1,
              hits[0].turnIndex.value == 0 else {
            fatalError("transcript.find could not locate the AdaptiveCard payload")
        }

        // 5. Announce success in the exact form the smoke runner
        //    greps for.
        print("PASS adaptivecards-swiftharness-roundtrip")
    }
}
