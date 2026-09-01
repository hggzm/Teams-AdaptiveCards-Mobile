// SwiftHarnessSession — bundle / lifecycle operations
//
// Four upstream-derived verbs that operate at the bundle level rather
// than mutating a single session in place:
//
//   - fork    — copy a session to a new id and append a prompt
//   - export  — return a single-blob `SessionExport` that bundles a
//               session + its transcript
//   - importBundle — write a previously-exported `SessionExport` back
//                    onto disk, preserving timestamps and id
//   - prune   — keep the N newest unpinned sessions; preserve every
//               pinned session unconditionally
//
// Every result type is `Codable` with snake_case JSON keys matching
// the upstream wire format.

import Foundation
import SwiftHarnessCore

// MARK: - Result types

/// Bundle returned by `SessionStore.export(...)`. Carries the entire
/// session-on-disk in a single value so it can be round-tripped via
/// `importBundle`.
public struct SessionExport: Equatable, Sendable, Codable {
    public let exportedSessionId: SessionId
    public let session: Session
    public let transcript: TranscriptRecord

    public init(exportedSessionId: SessionId,
                session: Session,
                transcript: TranscriptRecord) {
        self.exportedSessionId = exportedSessionId
        self.session = session
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case exportedSessionId = "exported_session_id"
        case session
        case transcript
    }
}

/// Result of `SessionStore.importBundle(...)`. Restates the id and
/// both persisted paths so machine-readable output never relies on
/// caller-side path concatenation.
public struct SessionImport: Equatable, Sendable, Codable {
    public let importedSessionId: SessionId
    public let sessionPath: String
    public let transcriptPath: String

    public init(importedSessionId: SessionId,
                sessionPath: String,
                transcriptPath: String) {
        self.importedSessionId = importedSessionId
        self.sessionPath = sessionPath
        self.transcriptPath = transcriptPath
    }

    enum CodingKeys: String, CodingKey {
        case importedSessionId = "imported_session_id"
        case sessionPath       = "session_path"
        case transcriptPath    = "transcript_path"
    }
}

/// Result of `SessionStore.fork(...)`. Reports both the source and
/// the newly-created forked session so callers can render "forked
/// X → Y at turn N".
public struct SessionFork: Equatable, Sendable, Codable {
    public let sourceSessionId: SessionId
    public let forkedSessionId: SessionId
    public let appendedTurnIndex: TurnIndex
    public let sessionPath: String
    public let transcriptPath: String

    public init(sourceSessionId: SessionId,
                forkedSessionId: SessionId,
                appendedTurnIndex: TurnIndex,
                sessionPath: String,
                transcriptPath: String) {
        self.sourceSessionId = sourceSessionId
        self.forkedSessionId = forkedSessionId
        self.appendedTurnIndex = appendedTurnIndex
        self.sessionPath = sessionPath
        self.transcriptPath = transcriptPath
    }

    enum CodingKeys: String, CodingKey {
        case sourceSessionId    = "source_session_id"
        case forkedSessionId    = "forked_session_id"
        case appendedTurnIndex  = "appended_turn_index"
        case sessionPath        = "session_path"
        case transcriptPath     = "transcript_path"
    }
}

/// One entry in `SessionPrune.removed`: identifies a session that
/// was deleted by the prune operation.
public struct SessionPruneRemoval: Equatable, Sendable, Codable {
    public let sessionId: SessionId
    public let sessionPath: String
    public let transcriptPath: String

    public init(sessionId: SessionId,
                sessionPath: String,
                transcriptPath: String) {
        self.sessionId = sessionId
        self.sessionPath = sessionPath
        self.transcriptPath = transcriptPath
    }

    enum CodingKeys: String, CodingKey {
        case sessionId      = "session_id"
        case sessionPath    = "session_path"
        case transcriptPath = "transcript_path"
    }
}

/// Result of `SessionStore.prune(keep:)`.
public struct SessionPrune: Equatable, Sendable, Codable {
    public let keptCount: Int
    public let prunedCount: Int
    public let pinnedPreservedCount: Int
    public let removed: [SessionPruneRemoval]
    public let pinnedPreserved: [SessionId]

    public init(keptCount: Int,
                prunedCount: Int,
                pinnedPreservedCount: Int,
                removed: [SessionPruneRemoval],
                pinnedPreserved: [SessionId]) {
        self.keptCount = keptCount
        self.prunedCount = prunedCount
        self.pinnedPreservedCount = pinnedPreservedCount
        self.removed = removed
        self.pinnedPreserved = pinnedPreserved
    }

    enum CodingKeys: String, CodingKey {
        case keptCount            = "kept_count"
        case prunedCount          = "pruned_count"
        case pinnedPreservedCount = "pinned_preserved_count"
        case removed
        case pinnedPreserved      = "pinned_preserved"
    }
}

// MARK: - SessionStore bundle operations

extension SessionStore {
    // Path helpers reused below; the originals are private to the
    // primary file so we recompute them here from the public root.
    private func sessionFile(for id: SessionId) -> URL {
        self.root.appendingPathComponent(id.description + Self.sessionSuffix)
    }
    private func transcriptFile(for id: SessionId) -> URL {
        self.root.appendingPathComponent(id.description + Self.transcriptSuffix)
    }

    // MARK: fork

    /// Create a new session that copies `id`'s messages + transcript
    /// and appends `prompt` as the next turn. The source session is
    /// untouched; the forked session has a fresh `SessionId`, no
    /// label, and `pinned: false`. Both `created_at_ms` and
    /// `updated_at_ms` on the forked session are set to the current
    /// clock value.
    @discardableResult
    public func fork(_ id: SessionId, prompt: Prompt) throws -> SessionFork {
        let source = try self.loadSession(id)
        let sourceTranscript = try self.loadTranscript(id)

        let now = self.clock.nowMs()
        let appendedTurn = TurnIndex(source.messages.count)

        // Build the forked session: copy messages, append new prompt;
        // copy usage and bump the input side for the new prompt.
        var newMessages = source.messages
        newMessages.append(prompt)
        let newUsage = UsageSummary(
            inputTokens:  source.usage.inputTokens
                              + estimateTokens(prompt.asString),
            outputTokens: source.usage.outputTokens
        )

        let forked = Session(
            sessionId: SessionId(),
            createdAtMs: now,
            updatedAtMs: now,
            messages: newMessages,
            usage: newUsage,
            label: nil,
            pinned: false
        )

        // Build the forked transcript: every original entry is
        // preserved with its original turn_index, then the new prompt
        // lands at `appendedTurn`.
        var newEntries = sourceTranscript.entries
        newEntries.append(TranscriptEntry(turnIndex: appendedTurn, prompt: prompt))
        let forkedTranscript = TranscriptRecord(
            sessionId: forked.sessionId,
            createdAtMs: now,
            updatedAtMs: now,
            entries: newEntries
        )

        try self.writeBundle(session: forked, transcript: forkedTranscript)

        return SessionFork(
            sourceSessionId: id,
            forkedSessionId: forked.sessionId,
            appendedTurnIndex: appendedTurn,
            sessionPath: self.sessionFile(for: forked.sessionId).path,
            transcriptPath: self.transcriptFile(for: forked.sessionId).path
        )
    }

    // MARK: export

    /// Snapshot a session into a `SessionExport` value. Pure read —
    /// does not mutate any on-disk state. Use `importBundle` to
    /// restore the export back onto disk later.
    public func export(_ id: SessionId) throws -> SessionExport {
        let session = try self.loadSession(id)
        let transcript = try self.loadTranscript(id)
        return SessionExport(
            exportedSessionId: id,
            session: session,
            transcript: transcript
        )
    }

    // MARK: importBundle

    /// Write a previously-exported `SessionExport` back onto disk.
    /// Preserves `created_at_ms`, `updated_at_ms`, the original
    /// `session_id`, the original transcript turn indexes, and the
    /// `label` / `pinned` flags exactly as the export bundle carried
    /// them. Throws:
    ///
    ///   - `invalidBundle` when the bundle's `exported_session_id`
    ///     does not match the nested `session.session_id` or
    ///     `transcript.session_id`.
    ///   - `invalidBundle` when a transcript entry's `turn_index` is
    ///     not the position-zero-anchored monotonic sequence
    ///     `[0, 1, 2, …]`.
    ///   - `sessionAlreadyExists` when a session or transcript file
    ///     already exists at the import path.
    @discardableResult
    public func importBundle(_ bundle: SessionExport) throws -> SessionImport {
        // Cross-check the embedded ids.
        if bundle.session.sessionId != bundle.exportedSessionId {
            throw HarnessError.invalidBundle(
                "exported_session_id \(bundle.exportedSessionId.description) does not match nested session.session_id \(bundle.session.sessionId.description)"
            )
        }
        if bundle.transcript.sessionId != bundle.exportedSessionId {
            throw HarnessError.invalidBundle(
                "exported_session_id \(bundle.exportedSessionId.description) does not match nested transcript.session_id \(bundle.transcript.sessionId.description)"
            )
        }

        // Validate monotonic turn-index sequence.
        for (position, entry) in bundle.transcript.entries.enumerated() {
            if entry.turnIndex.value != position {
                throw HarnessError.invalidBundle(
                    "transcript entry at position \(position) declares turn_index \(entry.turnIndex.value) (expected \(position))"
                )
            }
        }

        // Reject if either file already exists.
        let sURL = self.sessionFile(for: bundle.exportedSessionId)
        let tURL = self.transcriptFile(for: bundle.exportedSessionId)
        let fm = FileManager.default
        if fm.fileExists(atPath: sURL.path) || fm.fileExists(atPath: tURL.path) {
            throw HarnessError.sessionAlreadyExists(
                bundle.exportedSessionId.description
            )
        }

        try self.writeBundle(session: bundle.session,
                             transcript: bundle.transcript)

        return SessionImport(
            importedSessionId: bundle.exportedSessionId,
            sessionPath: sURL.path,
            transcriptPath: tURL.path
        )
    }

    // MARK: prune

    /// Remove every unpinned session except the newest `keep`. Pinned
    /// sessions are preserved unconditionally. Pure on the surviving
    /// sessions' metadata: `updated_at_ms` is NOT touched.
    ///
    /// `keep` must be `>= 0`. Pass `0` to drop every unpinned session.
    @discardableResult
    public func prune(keep: Int) throws -> SessionPrune {
        let rows = try self.list()
        let pinnedIds = rows.filter { $0.pinned }.map(\.sessionId)
        let pinnedCount = pinnedIds.count

        // The newest unpinned `keep` are kept; everything else is
        // pruned. `list()` already orders newest-first.
        let unpinned = rows.filter { !$0.pinned }
        let toKeep = Array(unpinned.prefix(max(0, keep)))
        let toPrune = Array(unpinned.dropFirst(toKeep.count))

        var removed: [SessionPruneRemoval] = []
        let fm = FileManager.default
        for row in toPrune {
            let sURL = self.sessionFile(for: row.sessionId)
            let tURL = self.transcriptFile(for: row.sessionId)
            if fm.fileExists(atPath: sURL.path) {
                do {
                    try fm.removeItem(at: sURL)
                } catch {
                    throw HarnessError.io(
                        "remove \(sURL.path): \(error.localizedDescription)"
                    )
                }
            }
            if fm.fileExists(atPath: tURL.path) {
                do {
                    try fm.removeItem(at: tURL)
                } catch {
                    throw HarnessError.io(
                        "remove \(tURL.path): \(error.localizedDescription)"
                    )
                }
            }
            removed.append(SessionPruneRemoval(
                sessionId: row.sessionId,
                sessionPath: sURL.path,
                transcriptPath: tURL.path
            ))
        }

        return SessionPrune(
            keptCount: toKeep.count,
            prunedCount: removed.count,
            pinnedPreservedCount: pinnedCount,
            removed: removed,
            pinnedPreserved: pinnedIds
        )
    }

    // MARK: rename

    /// Idempotently set the label on a session, whether it currently
    /// has one or not. Where `setLabel` throws on an already-labeled
    /// session and `retagLabel` throws on an unlabeled one, `rename`
    /// always succeeds (assuming the label itself validates) and
    /// returns a `SessionRename` envelope reporting the final label.
    /// Metadata-only — does NOT bump `updated_at_ms`.
    @discardableResult
    public func rename(_ id: SessionId, label: String) throws -> SessionRename {
        let normalized = try normalizeLabel(label)
        let current = try self.loadSession(id)
        if current.label == nil {
            try self.setLabel(id, label: normalized)
        } else {
            try self.retagLabel(id, label: normalized)
        }
        return SessionRename(
            renamedSessionId: id,
            appliedLabel: normalized
        )
    }
}

/// Result of `SessionStore.rename(_:label:)`.
public struct SessionRename: Equatable, Sendable, Codable {
    public let renamedSessionId: SessionId
    public let appliedLabel: String

    public init(renamedSessionId: SessionId, appliedLabel: String) {
        self.renamedSessionId = renamedSessionId
        self.appliedLabel = appliedLabel
    }

    enum CodingKeys: String, CodingKey {
        case renamedSessionId = "renamed_session_id"
        case appliedLabel     = "applied_label"
    }
}
