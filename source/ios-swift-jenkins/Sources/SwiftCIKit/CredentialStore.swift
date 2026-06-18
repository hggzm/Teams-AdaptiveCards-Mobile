import Foundation

/// Phase 37: persistent credential store.
///
/// Models a Jenkins-style `withCredentials([string(credentialsId:
/// 'X', variable: 'Y')]) { … }` workflow. A `Credential` is identified
/// by a stable `id` chosen by the operator and carries a single
/// `value`. The executor resolves a step's `credentials:` array at
/// build time and injects each resolved value into the step's
/// environment under the requested variable name.
///
/// Storage: a single JSON file at `<store-root>/credentials.json`
/// (envelope-versioned). Created lazily; readers tolerate it missing
/// and treat the store as empty. Values are stored in cleartext —
/// same threat model as `APITokenStore`: the controller process
/// already has full filesystem access to anything it could expose.
/// Operators who need encryption-at-rest can layer disk encryption.
public actor CredentialStore {

    /// Credential type. Only `string` is supported in v1 — usernames
    /// + private keys + multi-field bundles are out of scope. The
    /// type is wire-stable so future variants can be added without a
    /// schema break.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case string
    }

    /// One stored credential. `id` is the lookup key; `value` is
    /// returned only at creation and via in-process resolution from
    /// `BuildExecutor`. The HTTP layer MUST redact `value` on list
    /// responses.
    public struct Credential: Codable, Sendable, Equatable {
        public let id: String
        public let kind: Kind
        public let description: String
        public let value: String
        public let createdAt: Date

        public init(id: String, kind: Kind, description: String,
                    value: String, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.description = description
            self.value = value
            self.createdAt = createdAt
        }
    }

    private struct CredentialFile: Codable {
        var version: Int
        var credentials: [Credential]
    }

    private let url: URL
    private var cache: [Credential]?

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("credentials.json")
    }

    public init(jobStore: JobStore) {
        self.init(directory: jobStore.root)
    }

    // ──────────────────────────────────────────────────────────────
    // Read
    // ──────────────────────────────────────────────────────────────

    /// All credentials currently on disk, in insertion order. Caller
    /// is responsible for redacting `value` before serving to clients.
    public func list() throws -> [Credential] {
        try loadOrEmpty()
    }

    /// Resolve a single credential by id. Nil when not present.
    public func lookup(id: String) throws -> Credential? {
        let all = try loadOrEmpty()
        return all.first(where: { $0.id == id })
    }

    // ──────────────────────────────────────────────────────────────
    // Mutation
    // ──────────────────────────────────────────────────────────────

    public enum CreateError: Error, Equatable, Sendable {
        case idEmpty
        case valueEmpty
        case duplicateID(String)
    }

    /// Create or overwrite-blocked: throws on duplicate id. To rotate
    /// a credential's value, delete + recreate (keeps the audit trail
    /// honest: `createdAt` always reflects the current version).
    @discardableResult
    public func create(
        id: String,
        kind: Kind = .string,
        description: String = "",
        value: String
    ) throws -> Credential {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw CreateError.idEmpty }
        guard !value.isEmpty else { throw CreateError.valueEmpty }
        var all = try loadOrEmpty()
        if all.contains(where: { $0.id == trimmedID }) {
            throw CreateError.duplicateID(trimmedID)
        }
        let cred = Credential(
            id: trimmedID, kind: kind,
            description: description, value: value,
            createdAt: Date())
        all.append(cred)
        try save(all)
        return cred
    }

    public enum DeleteError: Error, Equatable, Sendable {
        case notFound(String)
    }

    public func delete(id: String) throws {
        var all = try loadOrEmpty()
        guard let idx = all.firstIndex(where: { $0.id == id }) else {
            throw DeleteError.notFound(id)
        }
        all.remove(at: idx)
        try save(all)
    }

    // ──────────────────────────────────────────────────────────────
    // private
    // ──────────────────────────────────────────────────────────────

    private func loadOrEmpty() throws -> [Credential] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = []
            return []
        }
        let raw = try AtomicIO.readString(from: url)
        let data = Data(raw.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(CredentialFile.self, from: data)
        cache = file.credentials
        return file.credentials
    }

    private func save(_ creds: [Credential]) throws {
        let envelope = CredentialFile(version: 1, credentials: creds)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try AtomicIO.writeData(data, to: url)
        cache = creds
    }
}
