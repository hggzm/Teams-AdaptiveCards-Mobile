import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fires HTTP POST notifications when a build reaches a terminal
/// state.
///
/// Conformers are expected to be safe to call concurrently; the
/// executor invokes `notify(_:pipeline:)` from its actor context but
/// implementations should not block the executor on slow HTTP.
public protocol BuildNotifier: Sendable {
    /// Called exactly once per build, after the build's terminal
    /// status has been persisted. Implementations decide whether each
    /// of `pipeline.notify` actually fires (`shouldFire(for:)` is the
    /// canonical check).
    func notify(build: Build, pipeline: Pipeline) async
}

/// JSON body posted to every notification URL.
///
/// Deliberately small and stable — receivers (Slack, Discord, custom
/// hooks) are expected to massage / re-shape on their end.
public struct BuildNotification: Codable, Sendable, Equatable {
    public let jobID: String
    public let pipelineName: String
    public let number: Int
    public let status: String
    public let exitCode: Int32?
    public let startedAt: Date?
    public let endedAt: Date?
    public let event: String   // always "build.completed" for now

    public init(build: Build, pipeline: Pipeline) {
        self.jobID = build.jobID
        self.pipelineName = pipeline.name
        self.number = build.number
        self.status = build.status.rawValue
        self.exitCode = build.exitCode
        self.startedAt = build.startedAt
        self.endedAt = build.endedAt
        self.event = "build.completed"
    }
}

/// Default `BuildNotifier`. POSTs JSON to every URL declared in
/// `pipeline.notify` that matches the build's terminal status.
///
/// Uses `Foundation.URLSession` (cross-platform — works on macOS,
/// Linux's `FoundationNetworking`, and Windows MSVC). Each POST
/// has its own timeout; a single hook timing out doesn't block
/// the others or stall the executor.
public struct URLSessionBuildNotifier: BuildNotifier {
    /// Per-request timeout. Default 10s — generous enough for Slack
    /// from a fresh TLS handshake, tight enough that a misconfigured
    /// hook can't park a build's notifier for minutes.
    public let timeout: TimeInterval
    /// Optional logger hook for test instrumentation. Receives one
    /// call per attempted notification with `(url, status code or nil
    /// on transport error, body or error description)`.
    public let logSink: (@Sendable (String, Int?, String) -> Void)?

    public init(
        timeout: TimeInterval = 10,
        logSink: (@Sendable (String, Int?, String) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.logSink = logSink
    }

    public func notify(build: Build, pipeline: Pipeline) async {
        guard !pipeline.notify.isEmpty else { return }
        let payload = BuildNotification(build: build, pipeline: pipeline)
        let data: Data
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys]
            data = try enc.encode(payload)
        } catch {
            logSink?("(encode-error)", nil, "could not encode payload: \(error)")
            return
        }

        // Fire all matching hooks concurrently. A slow hook doesn't
        // block the others; total time is bounded by `timeout`.
        await withTaskGroup(of: Void.self) { group in
            for entry in pipeline.notify where entry.shouldFire(for: build.status) {
                let url = entry.url
                let timeout = self.timeout
                let sink = self.logSink
                group.addTask {
                    await Self.send(url: url, data: data, timeout: timeout, log: sink)
                }
            }
        }
    }

    private static func send(
        url urlString: String,
        data: Data,
        timeout: TimeInterval,
        log: (@Sendable (String, Int?, String) -> Void)?
    ) async {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            log?(urlString, nil, "invalid URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("swiftci/\(SwiftCIApp.version)",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        do {
            let (responseData, response) = try await URLSession.shared.upload(
                for: request, from: data)
            let code = (response as? HTTPURLResponse)?.statusCode
            let bodyStr = String(data: responseData, encoding: .utf8) ?? ""
            log?(urlString, code, bodyStr)
        } catch {
            log?(urlString, nil, "\(error)")
        }
    }
}

/// `BuildNotifier` that does nothing. Used by tests + by the default
/// executor when no notifications are configured at the runtime
/// level. Distinct from `URLSessionBuildNotifier`-with-empty-notify
/// in that this implementation never even touches `URLSession`.
public struct NoopBuildNotifier: BuildNotifier {
    public init() {}
    public func notify(build: Build, pipeline: Pipeline) async {}
}
