import Foundation
import SwiftKaKit
import SwiftKaBridge

// Flavor A — "store": persist the canonical AdaptiveCards sample
// through the vendored swiftka kit, retrieve it byte-identically, and
// verify the SwiftKaKit version constant exposes the vendored kit's
// semver. Five distinct vendored symbols are touched:
//
//   1. SwiftKa.version             (kit version constant)
//   2. Database(path:)             (vendored SQLite + WAL bootstrap)
//   3. KeyStore(database:)         (high-level kv layer)
//   4. AdaptiveCardStore(path:)    (bridge surface)
//   5. AdaptiveCardStore.storeCard / .loadCard / .cardSize
//
// Stdout on success ends with `PASS adaptivecards-swiftka-roundtrip`,
// which the smoke scripts grep for.

enum DemoError: Error, CustomStringConvertible {
    case versionMissing
    case sizeMismatch(expected: Int, got: Int)
    case notFound
    case byteMismatch(expected: Int, got: Int)
    case parsedNotAdaptiveCard

    var description: String {
        switch self {
        case .versionMissing:
            return "SwiftKa.version is empty"
        case .sizeMismatch(let exp, let got):
            return "cardSize mismatch: expected \(exp), got \(got)"
        case .notFound:
            return "loadCard returned nil for a key we just stored"
        case .byteMismatch(let exp, let got):
            return "byte mismatch: expected \(exp), got \(got)"
        case .parsedNotAdaptiveCard:
            return "round-tripped JSON did not parse back to an AdaptiveCard"
        }
    }
}

func run() throws {
    // 1. Kit version probe — proves SwiftKa is reachable and the
    //    public type is the vendored one.
    let version = SwiftKa.version
    print("swiftka kit version: \(version)")
    guard !version.isEmpty else { throw DemoError.versionMissing }

    // 2-4. Open an ephemeral on-disk SQLite database via the bridge
    //      and persist the canonical card.
    let tmpDir = NSTemporaryDirectory()
    let dbPath = (tmpDir as NSString).appendingPathComponent("swiftka-adaptivecards-demo.sqlite3")
    // Best-effort cleanup of any stale leftovers from a prior run.
    try? FileManager.default.removeItem(atPath: dbPath)
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try AdaptiveCardStore(path: dbPath)
    let cardId = "ac.demo.hello"
    let payload = SampleCard.jsonBytes
    try store.storeCard(id: cardId, json: payload)
    print("stored \(payload.count) bytes under id=\(cardId)")

    // 5. Round-trip through cardSize + loadCard.
    let size = try store.cardSize(id: cardId)
    guard size == payload.count else {
        throw DemoError.sizeMismatch(expected: payload.count, got: size)
    }
    guard let readBack = try store.loadCard(id: cardId) else {
        throw DemoError.notFound
    }
    guard readBack == payload else {
        throw DemoError.byteMismatch(expected: payload.count, got: readBack.count)
    }
    print("round-trip ok — \(size) bytes")

    // Sanity: the read-back JSON should also parse as an Adaptive
    // Card (proves we stored the bytes intact end-to-end, not a
    // truncated / re-encoded prefix).
    let parsed = try JSONSerialization.jsonObject(with: readBack)
    guard let dict = parsed as? [String: Any],
          dict["type"] as? String == "AdaptiveCard" else {
        throw DemoError.parsedNotAdaptiveCard
    }
    print("parsed back to type=AdaptiveCard")
}

do {
    try run()
    print("PASS adaptivecards-swiftka-roundtrip")
} catch {
    FileHandle.standardError.write(Data("FAIL adaptivecards-swiftka-roundtrip: \(error)\n".utf8))
    exit(1)
}
