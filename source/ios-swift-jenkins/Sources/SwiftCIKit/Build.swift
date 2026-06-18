import Foundation

/// One build of a job. Builds are numbered per-job starting at 1.
///
/// On disk:
/// ```
/// <root>/jobs/<jobID>/builds/<number>/
///   status.json    ← this struct, serialized
///   log.txt        ← combined stdout/stderr from every step
/// ```
public struct Build: Codable, Sendable, Equatable {
    public let jobID: String
    public let number: Int
    public var status: BuildStatus
    /// Exit code of the first failing step, or 0 if `status == .passed`.
    public var exitCode: Int32?
    /// Phase 21: when this build entered the executor's FIFO queue,
    /// recorded by `JobStore.createBuild`. Optional for backward
    /// compatibility with builds persisted by older controller
    /// versions; missing values are simply not counted by the
    /// queue-wait histogram on `/metrics`.
    public var queuedAt: Date?
    public var startedAt: Date?
    public var endedAt: Date?
    /// Phase 33: trigger-time parameter overrides, merged into the
    /// step environment with higher precedence than per-step `env:`
    /// (so they override Phase-24 `parameters{}` defaults baked in by
    /// the importer) but lower than the executor's `SWIFTCI_*` keys.
    /// Optional and omitted from `status.json` when nil/empty for
    /// backward compatibility.
    public var parameters: [String: String]?

    public init(
        jobID: String,
        number: Int,
        status: BuildStatus = .queued,
        exitCode: Int32? = nil,
        queuedAt: Date? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        parameters: [String: String]? = nil
    ) {
        self.jobID = jobID
        self.number = number
        self.status = status
        self.exitCode = exitCode
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.parameters = parameters
    }

    // Custom Codable to omit `parameters` when nil/empty so old
    // status.json files round-trip unchanged and new ones don't grow
    // an empty dict for the common case.
    private enum CodingKeys: String, CodingKey {
        case jobID, number, status, exitCode, queuedAt, startedAt, endedAt, parameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jobID      = try c.decode(String.self,        forKey: .jobID)
        self.number     = try c.decode(Int.self,           forKey: .number)
        self.status     = try c.decode(BuildStatus.self,   forKey: .status)
        self.exitCode   = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        self.queuedAt   = try c.decodeIfPresent(Date.self,  forKey: .queuedAt)
        self.startedAt  = try c.decodeIfPresent(Date.self,  forKey: .startedAt)
        self.endedAt    = try c.decodeIfPresent(Date.self,  forKey: .endedAt)
        self.parameters = try c.decodeIfPresent([String: String].self,
                                                forKey: .parameters)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobID,  forKey: .jobID)
        try c.encode(number, forKey: .number)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(exitCode,  forKey: .exitCode)
        try c.encodeIfPresent(queuedAt,  forKey: .queuedAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt,   forKey: .endedAt)
        if let parameters, !parameters.isEmpty {
            try c.encode(parameters, forKey: .parameters)
        }
    }
}

/// Build state machine.
///
/// ```
/// queued ──► running ──┬──► passed
///                      ├──► failed
///                      └──► canceled
/// ```
public enum BuildStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case queued
    case running
    case passed
    case failed
    case canceled

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:  return false
        case .passed, .failed, .canceled:  return true
        }
    }
}
