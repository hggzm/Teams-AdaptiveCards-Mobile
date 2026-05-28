// SwiftHarnessSession — Transcript inspection
//
// 20 pure inspection verbs over `TranscriptRecord` that match the
// upstream Rust harness's transcript-* CLI surface. Every verb is a
// pure function of `self.entries` sorted by `turn_index` ascending,
// so results are deterministic and trivially testable without any
// provider, filesystem, or wall-clock dependency.
//
// The verbs:
//
//   Counts / predicates:
//     - entryCount()                                    Int
//     - hasEntries()                                    Bool
//     - turnExists(at:)                                 Bool
//     - hasTurnGaps()                                   Bool
//
//   Lookups:
//     - firstTurn()                                     TranscriptEntry?
//     - lastTurn()                                      TranscriptEntry?
//     - turnShow(at:)                                   throws -> TranscriptEntry
//
//   Slices:
//     - tail(count:)                                    [TranscriptEntry]
//     - range(startTurnIndex:requestedCount:)           [TranscriptEntry]
//     - context(around:before:after:)                   [TranscriptEntry]
//
//   Search:
//     - find(query:)                                    [TranscriptFindMatch]
//
//   Turn-index analysis:
//     - turnIndexes()                                   [TurnIndex]
//     - turnIndexRange()                                (TurnIndex, TurnIndex)?
//     - missingTurnIndexes()                            [TurnIndex]
//     - missingTurnCount()                              Int
//     - turnDensity()                                   Double in [0, 1]
//
//   Gap analysis:
//     - gapRanges()                                     [TranscriptGapRange]
//     - gapCount()                                      Int
//     - largestGap()                                    TranscriptGapRange?
//     - smallestGap()                                   TranscriptGapRange?

import Foundation
import SwiftHarnessCore

// MARK: - Result types

/// One hit returned by `TranscriptRecord.find(query:)`.
///
/// JSON wire shape: `{"prompt": "...", "turn_index": N}` with sorted
/// keys, matching the upstream `SessionFindMatch` struct.
public struct TranscriptFindMatch: Equatable, Sendable, Codable {
    /// Turn index at which the match was recorded.
    public let turnIndex: TurnIndex

    /// The prompt text that contained the query substring.
    public let prompt: Prompt

    public init(turnIndex: TurnIndex, prompt: Prompt) {
        self.turnIndex = turnIndex
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case turnIndex = "turn_index"
        case prompt
    }
}

/// A contiguous block of missing turn indexes inside the transcript's
/// declared turn-index range. `start` and `end` are both inclusive.
///
/// JSON wire shape: `{"end": N, "length": K, "start": N}` with sorted
/// keys.
public struct TranscriptGapRange: Equatable, Sendable, Codable {
    /// First missing turn index in the gap.
    public let start: TurnIndex

    /// Last missing turn index in the gap (inclusive).
    public let end: TurnIndex

    /// Number of missing turn indexes covered by this gap (always ≥ 1).
    public var length: Int {
        self.end.value - self.start.value + 1
    }

    public init(start: TurnIndex, end: TurnIndex) {
        self.start = start
        self.end = end
    }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case length
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.start = try c.decode(TurnIndex.self, forKey: .start)
        self.end   = try c.decode(TurnIndex.self, forKey: .end)
        // `length` is derived; ignore on decode.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.start,  forKey: .start)
        try c.encode(self.end,    forKey: .end)
        try c.encode(self.length, forKey: .length)
    }
}

// MARK: - TranscriptRecord inspection

extension TranscriptRecord {
    /// Entries sorted by `turn_index` ascending. This is the canonical
    /// view every inspection verb operates on, so a transcript loaded
    /// out-of-order from disk still produces well-defined results.
    public var sortedEntries: [TranscriptEntry] {
        self.entries.sorted { $0.turnIndex.value < $1.turnIndex.value }
    }

    // MARK: Counts / predicates

    /// Total number of entries in this transcript.
    public func entryCount() -> Int { self.entries.count }

    /// `true` when this transcript has any entries.
    public func hasEntries() -> Bool { !self.entries.isEmpty }

    /// `true` when an entry with the given turn index exists.
    public func turnExists(at index: TurnIndex) -> Bool {
        self.entries.contains { $0.turnIndex == index }
    }

    /// `true` when the contiguous span between the first and last
    /// observed turn index contains at least one missing index. An
    /// empty transcript reports no gaps.
    public func hasTurnGaps() -> Bool {
        guard let bounds = self.turnIndexRange() else { return false }
        let span = bounds.last.value - bounds.first.value + 1
        return self.entries.count < span
    }

    // MARK: Lookups

    /// The earliest entry by turn index, or `nil` if empty.
    public func firstTurn() -> TranscriptEntry? {
        self.sortedEntries.first
    }

    /// The latest entry by turn index, or `nil` if empty.
    public func lastTurn() -> TranscriptEntry? {
        self.sortedEntries.last
    }

    /// The entry at the given turn index. Throws
    /// `HarnessError.transcriptTurnOutOfRange` when no such entry
    /// exists. The error payload is the decimal turn index, matching
    /// the upstream Rust error wording.
    public func turnShow(at index: TurnIndex) throws -> TranscriptEntry {
        if let entry = self.entries.first(where: { $0.turnIndex == index }) {
            return entry
        }
        throw HarnessError.transcriptTurnOutOfRange(String(index.value))
    }

    // MARK: Slices

    /// The last `count` entries by turn-index order. Negative or zero
    /// counts return an empty array; counts larger than the transcript
    /// return every entry.
    public func tail(count: Int) -> [TranscriptEntry] {
        guard count > 0 else { return [] }
        return Array(self.sortedEntries.suffix(count))
    }

    /// Up to `requestedCount` entries starting at the first entry whose
    /// `turn_index` is greater than or equal to `startTurnIndex`. The
    /// selector is by value, not by position, so a sparse transcript
    /// returns a contiguous slice of *recorded* entries from the
    /// matching point forward.
    public func range(startTurnIndex: TurnIndex,
                      requestedCount: Int) -> [TranscriptEntry] {
        guard requestedCount > 0 else { return [] }
        let candidates = self.sortedEntries
            .filter { $0.turnIndex.value >= startTurnIndex.value }
        return Array(candidates.prefix(requestedCount))
    }

    /// Up to `before` entries immediately preceding the entry at
    /// `target`, the target entry itself, and up to `after` entries
    /// immediately following — all by sorted-position order. Returns
    /// an empty array if the target turn index is not present.
    public func context(around target: TurnIndex,
                        before: Int,
                        after: Int) -> [TranscriptEntry] {
        let sorted = self.sortedEntries
        guard let pivot = sorted.firstIndex(where: { $0.turnIndex == target })
        else { return [] }
        let beforeN = max(0, before)
        let afterN  = max(0, after)
        let lo = Swift.max(0, pivot - beforeN)
        let hi = Swift.min(sorted.count - 1, pivot + afterN)
        return Array(sorted[lo...hi])
    }

    // MARK: Search

    /// Case-insensitive substring search across prompts. Matches are
    /// returned in `turn_index` ascending order. An empty `query`
    /// matches every entry, matching the upstream Rust convention
    /// (`str::contains("")` is true; Swift's `String.contains("")` is
    /// false, so we special-case the empty needle here).
    public func find(query: String) -> [TranscriptFindMatch] {
        let needle = query.lowercased()
        let matches: [TranscriptEntry]
        if needle.isEmpty {
            matches = self.sortedEntries
        } else {
            matches = self.sortedEntries
                .filter { $0.prompt.asString.lowercased().contains(needle) }
        }
        return matches.map {
            TranscriptFindMatch(turnIndex: $0.turnIndex, prompt: $0.prompt)
        }
    }

    // MARK: Turn-index analysis

    /// Every observed turn index, ascending.
    public func turnIndexes() -> [TurnIndex] {
        self.sortedEntries.map(\.turnIndex)
    }

    /// `(first, last)` pair of the observed turn-index range, or `nil`
    /// when the transcript is empty.
    public func turnIndexRange() -> (first: TurnIndex, last: TurnIndex)? {
        let indexes = self.turnIndexes()
        guard let first = indexes.first, let last = indexes.last else {
            return nil
        }
        return (first, last)
    }

    /// Every integer in `[first, last]` that is NOT present in the
    /// transcript, ascending. An empty transcript yields an empty list.
    public func missingTurnIndexes() -> [TurnIndex] {
        guard let bounds = self.turnIndexRange() else { return [] }
        let present = Set(self.entries.map(\.turnIndex.value))
        var out: [TurnIndex] = []
        for v in bounds.first.value...bounds.last.value where !present.contains(v) {
            out.append(TurnIndex(v))
        }
        return out
    }

    /// Count of missing turn indexes inside `[first, last]`. `0` for
    /// an empty transcript.
    public func missingTurnCount() -> Int {
        self.missingTurnIndexes().count
    }

    /// Ratio `entryCount / span` where `span = last - first + 1`. Falls
    /// in `[0, 1]`; returns `0.0` for an empty transcript and `1.0`
    /// for a fully dense transcript.
    public func turnDensity() -> Double {
        guard let bounds = self.turnIndexRange() else { return 0.0 }
        let span = bounds.last.value - bounds.first.value + 1
        guard span > 0 else { return 0.0 }
        return Double(self.entries.count) / Double(span)
    }

    // MARK: Gap analysis

    /// Contiguous runs of missing turn indexes inside `[first, last]`,
    /// ascending by `start`. An empty transcript or a fully dense
    /// transcript yields an empty array.
    public func gapRanges() -> [TranscriptGapRange] {
        let missing = self.missingTurnIndexes().map(\.value)
        guard let head = missing.first else { return [] }
        var ranges: [TranscriptGapRange] = []
        var runStart = head
        var runPrev  = head
        for v in missing.dropFirst() {
            if v == runPrev + 1 {
                runPrev = v
            } else {
                ranges.append(TranscriptGapRange(
                    start: TurnIndex(runStart),
                    end:   TurnIndex(runPrev)
                ))
                runStart = v
                runPrev  = v
            }
        }
        ranges.append(TranscriptGapRange(
            start: TurnIndex(runStart),
            end:   TurnIndex(runPrev)
        ))
        return ranges
    }

    /// Number of distinct gap runs inside `[first, last]`.
    public func gapCount() -> Int { self.gapRanges().count }

    /// The widest gap by `length`, or `nil` when there are no gaps.
    /// Ties broken by earlier `start`.
    public func largestGap() -> TranscriptGapRange? {
        var best: TranscriptGapRange?
        for gap in self.gapRanges() {
            if let current = best {
                if gap.length > current.length {
                    best = gap
                }
            } else {
                best = gap
            }
        }
        return best
    }

    /// The narrowest gap by `length`, or `nil` when there are no gaps.
    /// Ties broken by earlier `start`.
    public func smallestGap() -> TranscriptGapRange? {
        var best: TranscriptGapRange?
        for gap in self.gapRanges() {
            if let current = best {
                if gap.length < current.length {
                    best = gap
                }
            } else {
                best = gap
            }
        }
        return best
    }
}
