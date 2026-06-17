// main.swift
//
// Runtime symbol-check demo for the vendored SwiftSyncCore kit — flavor A
// ("store / round-trip").
//
// It takes the canonical adaptivecards.io "Hello World" card, writes it into a
// temp SOURCE directory, drives the vendored `Syncer` to recursively copy that
// directory into a temp DESTINATION directory, reads the card back from the
// destination, and asserts the bytes are byte-for-byte identical. It then uses
// `FSOps` to prove a second pass would be a no-op (the decision is `.skip`).
//
// On success it prints exactly:  PASS adaptivecards-swiftsync-roundtrip
// On any failure it writes a FAIL line to stderr and exits non-zero, so the
// smoke scripts and CI gate on the PASS line.
//
// Symbols exercised (>= 3 distinct public SwiftSyncCore symbols):
//   1. Syncer(source:destination:options:) + Syncer.run()
//   2. Syncer.Options(preservePermissions:exclude:delete:copyLinks:)
//   3. SyncSummary / SyncStats.filesCopied
//   4. FSOps.stat(at:) + FSOps.decideCopy(source:destination:) (+ CopyDecision)
//   5. HumanSize.string(_:)

import Foundation
import SwiftSyncCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL adaptivecards-swiftsync-roundtrip: \(message)\n".utf8))
    exit(1)
}

// 1. Lay down the canonical card in a temp SOURCE directory.
let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("acm-swiftsync-\(UUID().uuidString)")
let srcDir = work.appendingPathComponent("src")
let dstDir = work.appendingPathComponent("dst")
defer { try? fm.removeItem(at: work) }

do {
    try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
} catch {
    fail("could not create source dir: \(error)")
}

let cardName = "hello-world.card.json"
let originalBytes = Data(SampleCard.helloWorldJSON.utf8)
let srcCard = srcDir.appendingPathComponent(cardName)
do {
    try originalBytes.write(to: srcCard)
} catch {
    fail("could not write source card: \(error)")
}

// 2. Drive the vendored Syncer to copy SRC -> DST. POSIX permission bits are not
//    meaningful on Windows, so preservation is off here.
let options = Syncer.Options(
    preservePermissions: false,
    exclude: [],
    delete: false,
    copyLinks: false
)
let syncer = Syncer(source: srcDir, destination: dstDir, options: options)

let summary: SyncSummary
do {
    summary = try await syncer.run()
} catch {
    fail("sync threw: \(error)")
}

guard summary.succeeded else {
    fail("sync reported \(summary.stats.errors) error(s): \(summary.failures)")
}
guard summary.stats.filesCopied == 1 else {
    fail("expected exactly 1 file copied, got \(summary.stats.filesCopied)")
}

// 3. Read the card back from the DESTINATION and assert byte-identical.
let dstCard = dstDir.appendingPathComponent(cardName)
let readBack: Data
do {
    readBack = try Data(contentsOf: dstCard)
} catch {
    fail("could not read destination card: \(error)")
}
guard readBack == originalBytes else {
    fail("round-trip byte mismatch (src \(originalBytes.count) B vs dst \(readBack.count) B)")
}

// 4. Use FSOps to prove a re-sync would be a no-op: stat both sides and confirm
//    the pure copy decision is `.skip` (destination already current).
let srcStat: FileStat?
let dstStat: FileStat?
do {
    srcStat = try FSOps.stat(at: srcCard)
    dstStat = try FSOps.stat(at: dstCard)
} catch {
    fail("FSOps.stat threw: \(error)")
}
guard let s = srcStat, let d = dstStat else {
    fail("FSOps.stat returned nil for a file that exists")
}
guard FSOps.decideCopy(source: s, destination: d) == .skip else {
    fail("expected a re-sync to be a no-op (.skip), but the decision was to copy")
}

// 5. Sanity-check the parsed card shape (Foundation JSONSerialization) and
//    format the transferred size with the kit's HumanSize formatter.
let parsedType: String
do {
    let obj = try JSONSerialization.jsonObject(with: readBack) as? [String: Any]
    let body = obj?["body"] as? [[String: Any]]
    parsedType = (body?.first?["type"] as? String) ?? "<none>"
} catch {
    fail("destination card is not valid JSON: \(error)")
}
guard parsedType == "TextBlock" else {
    fail("expected body[0].type == TextBlock, got \(parsedType)")
}

let human = HumanSize.string(summary.stats.bytesCopied)
print("synced 1 card (\(human)); body[0].type = \(parsedType); re-sync decision = skip")
print("PASS adaptivecards-swiftsync-roundtrip")
