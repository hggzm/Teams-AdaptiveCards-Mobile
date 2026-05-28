// SwiftHarnessSession — SessionStore
//
// Actor that owns the on-disk `.sessions/` directory. Each session
// occupies two files at the store root:
//
//     {root}/{session_id}.json              (Session bundle)
//     {root}/{session_id}.transcript.json   (TranscriptRecord bundle)
//
// All writes use the tmp-then-move pattern: write to
// `{path}.tmp-{pid}`, then move into place. `FileManager.replaceItemAt`
// is intentionally avoided — it is not implemented on
// swift-corelibs-foundation on Windows and triggers a process-killing
// `fatalError` if called there.
//
// Determinism rules enforced here (matching the upstream Rust
// workspace):
//
//   - `updated_at_ms` is bumped on `appendTurn(...)` and on any other
//     prompt-affecting change. It is deliberately NOT bumped by
//     label / pin / unlabel / retag / unpin operations.
//   - `list()` returns sessions newest-first by `updated_at_ms DESC`,
//     `created_at_ms DESC`, `session_id`, `persisted_path`.
//   - Labels are not enforced unique; duplicate labels surface as
//     `ambiguousLabel` only when a `label:<name>` selector is resolved.

import Foundation
import SwiftHarnessCore

// MARK: - SessionListing

/// One row of the `list()` output. Mirrors the upstream
/// `SessionListing` struct, with snake_case JSON keys.
public struct SessionListing: Equatable, Sendable, Codable {
    public var sessionId: SessionId
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var messageCount: Int
    public var persistedPath: String
    public var pinned: Bool
    public var label: String?

    public init(
        sessionId: SessionId,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        messageCount: Int,
        persistedPath: String,
        pinned: Bool,
        label: String?
    ) {
        self.sessionId = sessionId
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.messageCount = messageCount
        self.persistedPath = persistedPath
        self.pinned = pinned
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case sessionId     = "session_id"
        case createdAtMs   = "created_at_ms"
        case updatedAtMs   = "updated_at_ms"
        case messageCount  = "message_count"
        case persistedPath = "persisted_path"
        case pinned
        case label
    }
}

// MARK: - SessionStore

/// Actor that owns a single `.sessions/` directory.
public actor SessionStore {
    /// Root directory holding all `{session_id}.json` and
    /// `{session_id}.transcript.json` files.
    public let root: URL

    /// Clock used to stamp `created_at_ms` and `updated_at_ms`.
    public let clock: HarnessClock

    /// File suffix for the session bundle.
    public static let sessionSuffix: String = ".json"

    /// File suffix for the transcript bundle.
    public static let transcriptSuffix: String = ".transcript.json"

    /// Build a store rooted at `root`. The directory is created on
    /// demand the first time it is needed.
    public init(root: URL, clock: HarnessClock = SystemClock()) {
        self.root = root
        self.clock = clock
    }

    // MARK: - Filesystem helpers

    private func ensureRoot() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: self.root.path) {
            do {
                try fm.createDirectory(
                    at: self.root,
                    withIntermediateDirectories: true
                )
            } catch {
                throw HarnessError.io(
                    "create root \(self.root.path): \(error.localizedDescription)"
                )
            }
        }
    }

    private func sessionURL(for id: SessionId) -> URL {
        self.root.appendingPathComponent(id.description + Self.sessionSuffix)
    }

    private func transcriptURL(for id: SessionId) -> URL {
        self.root.appendingPathComponent(id.description + Self.transcriptSuffix)
    }

    /// Cross-platform "atomic-ish" write: write to a tmp sibling,
    /// remove the destination if it exists, then move tmp into place.
    /// Used in lieu of `FileManager.replaceItemAt`, which is not
    /// implemented on swift-corelibs-foundation on Windows.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp-\(pid)")
        // Clear any prior tmp file from an interrupted run.
        try? fm.removeItem(at: tmp)
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw HarnessError.io(
                "write \(tmp.path): \(error.localizedDescription)"
            )
        }
        if fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                throw HarnessError.io(
                    "remove \(url.path): \(error.localizedDescription)"
                )
            }
        }
        do {
            try fm.moveItem(at: tmp, to: url)
        } catch {
            throw HarnessError.io(
                "move \(tmp.path) → \(url.path): \(error.localizedDescription)"
            )
        }
    }

    /// Configured JSON encoder. Sorted keys + pretty-printed output so
    /// fixtures and on-disk bundles are byte-stable across runs.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try self.makeEncoder().encode(value)
        } catch {
            throw HarnessError.serialization(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HarnessError.serialization(error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    /// Create a fresh session and persist both its session and (empty)
    /// transcript bundles. Returns the new `Session`.
    @discardableResult
    public func createSession() throws -> Session {
        try self.ensureRoot()
        let now = self.clock.nowMs()
        let session = Session(
            sessionId: SessionId(),
            createdAtMs: now,
            updatedAtMs: now
        )
        let transcript = TranscriptRecord(
            sessionId: session.sessionId,
            createdAtMs: now,
            updatedAtMs: now
        )
        try self.writeBundle(session: session, transcript: transcript)
        return session
    }

    /// Persist both session and transcript bundles for `session`.
    /// Used by callers that mutate sessions out-of-band (rare; most
    /// mutations go through the dedicated mutator methods below).
    public func writeBundle(session: Session, transcript: TranscriptRecord) throws {
        try self.ensureRoot()
        try self.atomicWrite(try self.encode(session),
                             to: self.sessionURL(for: session.sessionId))
        try self.atomicWrite(try self.encode(transcript),
                             to: self.transcriptURL(for: session.sessionId))
    }

    /// Load the `Session` bundle for `id`. Throws
    /// `sessionNotFound` if absent and `invalidBundle` if the file
    /// exists but contains a different `session_id`.
    public func loadSession(_ id: SessionId) throws -> Session {
        let url = self.sessionURL(for: id)
        guard let data = try? Data(contentsOf: url) else {
            throw HarnessError.sessionNotFound(id.description)
        }
        let session = try self.decode(Session.self, from: data)
        if session.sessionId != id {
            throw HarnessError.invalidBundle(
                "session id mismatch in \(url.lastPathComponent)"
            )
        }
        return session
    }

    /// Load the `TranscriptRecord` bundle for `id`. Throws
    /// `sessionNotFound` if absent and `invalidBundle` if the file
    /// exists but carries a different `session_id`.
    public func loadTranscript(_ id: SessionId) throws -> TranscriptRecord {
        let url = self.transcriptURL(for: id)
        guard let data = try? Data(contentsOf: url) else {
            throw HarnessError.sessionNotFound(id.description)
        }
        let record = try self.decode(TranscriptRecord.self, from: data)
        if record.sessionId != id {
            throw HarnessError.invalidBundle(
                "transcript id mismatch in \(url.lastPathComponent)"
            )
        }
        return record
    }

    /// Delete both files for `id`. Throws `sessionNotFound` if the
    /// session bundle is absent (transcript-only orphans are ignored).
    public func deleteSession(_ id: SessionId) throws {
        let fm = FileManager.default
        let sURL = self.sessionURL(for: id)
        let tURL = self.transcriptURL(for: id)
        guard fm.fileExists(atPath: sURL.path) else {
            throw HarnessError.sessionNotFound(id.description)
        }
        do {
            try fm.removeItem(at: sURL)
        } catch {
            throw HarnessError.io("remove \(sURL.path): \(error.localizedDescription)")
        }
        if fm.fileExists(atPath: tURL.path) {
            try? fm.removeItem(at: tURL)
        }
    }

    // MARK: - Listing

    /// List every persisted session, newest-first by
    /// `updated_at_ms DESC`, `created_at_ms DESC`, `session_id`, then
    /// `persisted_path`.
    public func list() throws -> [SessionListing] {
        try self.ensureRoot()
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(
                at: self.root,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw HarnessError.io(
                "list \(self.root.path): \(error.localizedDescription)"
            )
        }
        var rows: [SessionListing] = []
        for url in items {
            let name = url.lastPathComponent
            // Only the session bundle drives the listing. Transcript
            // bundles are ignored here (their lifecycle is tied to
            // the session bundle).
            guard name.hasSuffix(Self.sessionSuffix),
                  !name.hasSuffix(Self.transcriptSuffix)
            else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let session = try? self.decode(Session.self, from: data)
            else { continue }
            rows.append(SessionListing(
                sessionId: session.sessionId,
                createdAtMs: session.createdAtMs,
                updatedAtMs: session.updatedAtMs,
                messageCount: session.messages.count,
                persistedPath: url.path,
                pinned: session.pinned,
                label: session.label
            ))
        }
        rows.sort { lhs, rhs in
            if lhs.updatedAtMs != rhs.updatedAtMs {
                return lhs.updatedAtMs > rhs.updatedAtMs
            }
            if lhs.createdAtMs != rhs.createdAtMs {
                return lhs.createdAtMs > rhs.createdAtMs
            }
            if lhs.sessionId.description != rhs.sessionId.description {
                return lhs.sessionId.description < rhs.sessionId.description
            }
            return lhs.persistedPath < rhs.persistedPath
        }
        return rows
    }

    // MARK: - Selector resolution

    /// Resolve `selector` (raw id, `latest`, or `label:<name>`) to a
    /// concrete `SessionId` and the loaded `Session`. Throws
    /// `malformedSelector`, `sessionNotFound`, or `ambiguousLabel`.
    public func resolveSelector(_ raw: String) throws -> Session {
        let selector = try SessionSelector.parse(raw)
        return try self.resolveSelector(selector)
    }

    /// Resolve a parsed `SessionSelector`. Identical semantics to the
    /// string overload.
    public func resolveSelector(_ selector: SessionSelector) throws -> Session {
        switch selector {
        case .latest:
            let rows = try self.list()
            guard let head = rows.first else {
                throw HarnessError.sessionNotFound(SessionSelector.latestKeyword)
            }
            return try self.loadSession(head.sessionId)

        case .label(let target):
            let rows = try self.list()
            let matches = rows.filter { $0.label == target }
            if matches.isEmpty {
                throw HarnessError.sessionNotFound("label:\(target)")
            }
            if matches.count > 1 {
                throw HarnessError.ambiguousLabel(target)
            }
            return try self.loadSession(matches[0].sessionId)

        case .id(let raw):
            guard let id = SessionId(string: raw) else {
                throw HarnessError.malformedSelector(raw)
            }
            return try self.loadSession(id)
        }
    }

    // MARK: - Mutators (prompt-affecting → bump updated_at_ms)

    /// Append a new prompt to `session`, write the corresponding
    /// transcript entry, bump `updated_at_ms`, and persist both
    /// bundles. Returns the updated `Session`.
    @discardableResult
    public func appendTurn(_ id: SessionId, prompt: Prompt) throws -> Session {
        var session = try self.loadSession(id)
        var transcript = try self.loadTranscript(id)

        let now = self.clock.nowMs()
        let nextIndex = TurnIndex(transcript.entries.count)
        transcript.entries.append(TranscriptEntry(turnIndex: nextIndex, prompt: prompt))
        transcript.updatedAtMs = now

        session.messages.append(prompt)
        // Only the input side of the usage tally moves here; output
        // tokens are attributed by the runtime when a real provider
        // (or `FakeProvider`) produces a response. We do NOT pipe an
        // empty string through `UsageSummary.addingTurn(...)` because
        // `estimateTokens("")` is intentionally floored to 1, which
        // would incorrectly credit the output side.
        session.usage = UsageSummary(
            inputTokens:  session.usage.inputTokens + estimateTokens(prompt.asString),
            outputTokens: session.usage.outputTokens
        )
        session.updatedAtMs = now

        try self.writeBundle(session: session, transcript: transcript)
        return session
    }

    // MARK: - Mutators (metadata only → do NOT bump updated_at_ms)

    /// Apply a label to a session that currently has none. Throws
    /// `sessionAlreadyLabeled` if the session already has a label
    /// (use `retagLabel` to change a label) and `invalidLabel` if
    /// the label is empty / whitespace.
    public func setLabel(_ id: SessionId, label: String) throws {
        let normalized = try normalizeLabel(label)
        var session = try self.loadSession(id)
        if session.label != nil {
            throw HarnessError.sessionAlreadyLabeled(id.description)
        }
        session.label = normalized
        try self.persistMetadataOnly(session)
    }

    /// Replace an existing label, regardless of its prior value. The
    /// session must currently have a label; otherwise call
    /// `setLabel`. Throws `sessionAlreadyUnlabeled` if no current
    /// label.
    public func retagLabel(_ id: SessionId, label: String) throws {
        let normalized = try normalizeLabel(label)
        var session = try self.loadSession(id)
        guard session.label != nil else {
            throw HarnessError.sessionAlreadyUnlabeled(id.description)
        }
        session.label = normalized
        try self.persistMetadataOnly(session)
    }

    /// Strip the label off a session. Throws
    /// `sessionAlreadyUnlabeled` if no current label.
    public func removeLabel(_ id: SessionId) throws {
        var session = try self.loadSession(id)
        guard session.label != nil else {
            throw HarnessError.sessionAlreadyUnlabeled(id.description)
        }
        session.label = nil
        try self.persistMetadataOnly(session)
    }

    /// Pin a session. Throws `sessionAlreadyPinned` if already pinned.
    public func pin(_ id: SessionId) throws {
        var session = try self.loadSession(id)
        if session.pinned {
            throw HarnessError.sessionAlreadyPinned(id.description)
        }
        session.pinned = true
        try self.persistMetadataOnly(session)
    }

    /// Unpin a session. Throws `sessionAlreadyUnpinned` if not pinned.
    public func unpin(_ id: SessionId) throws {
        var session = try self.loadSession(id)
        if !session.pinned {
            throw HarnessError.sessionAlreadyUnpinned(id.description)
        }
        session.pinned = false
        try self.persistMetadataOnly(session)
    }

    /// Persist a session whose mutation was metadata-only — i.e. it
    /// must NOT bump `updated_at_ms`. The transcript file is left
    /// untouched.
    private func persistMetadataOnly(_ session: Session) throws {
        try self.ensureRoot()
        try self.atomicWrite(try self.encode(session),
                             to: self.sessionURL(for: session.sessionId))
    }
}
