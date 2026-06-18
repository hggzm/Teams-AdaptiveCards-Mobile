// SwiftOAuthServer — loopback OAuth callback server (RFC 8252 §7.3).
//
// Captures exactly one authorization-code redirect on 127.0.0.1, validates the
// CSRF `state` (RFC 6749 §10.12) with a constant-time exact match, serves a
// "you may close this tab" page, and shuts the server down. No TLS is involved
// (loopback only) — and there is deliberately no insecure escape hatch.
import Foundation
import Hummingbird
import NIOCore
import SwiftOAuthCore

/// A one-shot loopback server that waits for a single OAuth callback.
public final class CallbackServer: Sendable {
    private let config: CallbackServerConfig

    public init(config: CallbackServerConfig) {
        self.config = config
    }

    /// One-shot latch holding the bound port and the awaited callback outcome,
    /// each delivered exactly once across the server task and the request
    /// handler.
    private actor Latch {
        private var portContinuation: CheckedContinuation<Int, Never>?
        private var portValue: Int?
        private var outcomeContinuation: CheckedContinuation<CallbackOutcome, Never>?
        private var outcomeValue: CallbackOutcome?

        func waitForPort() async -> Int {
            if let portValue { return portValue }
            return await withCheckedContinuation { portContinuation = $0 }
        }

        func resolvePort(_ port: Int) {
            guard portValue == nil else { return }
            portValue = port
            portContinuation?.resume(returning: port)
            portContinuation = nil
        }

        func waitForOutcome() async -> CallbackOutcome {
            if let outcomeValue { return outcomeValue }
            return await withCheckedContinuation { outcomeContinuation = $0 }
        }

        /// Resolve the outcome exactly once; later callbacks are ignored.
        /// Returns true if this call is the one that resolved it.
        @discardableResult
        func resolveOutcome(_ outcome: CallbackOutcome) -> Bool {
            guard outcomeValue == nil else { return false }
            outcomeValue = outcome
            outcomeContinuation?.resume(returning: outcome)
            outcomeContinuation = nil
            return true
        }
    }

    /// The result of running the callback server.
    public struct RunResult: Sendable {
        public let outcome: CallbackOutcome
        /// The port the server actually bound (useful when `config.port == 0`).
        public let boundPort: Int
        /// The exact loopback redirect URI the provider redirected to.
        public let redirectURI: URL
    }

    /// Start the loopback server, block until one callback is captured (or the
    /// task is cancelled), then shut down and return the outcome.
    ///
    /// - Parameter onBound: invoked with the exact loopback redirect URI once
    ///   the server is listening — the caller opens the browser to the
    ///   provider's authorize URL built with this redirect URI.
    public func run(
        onBound: (@Sendable (URL) async -> Void)? = nil
    ) async throws -> RunResult {
        let latch = Latch()
        let config = self.config

        let router = Router()
        router.get(RouterPath(config.path)) { request, _ -> Response in
            let outcome = Self.classify(query: request.uri.queryParameters, expectedState: config.expectedState)
            await latch.resolveOutcome(outcome)
            return Self.htmlResponse(for: outcome, successHTML: config.successHTML)
        }

        let app = CallbackApplication(
            appResponder: router.buildResponder(),
            host: config.host,
            port: config.port,
            onBound: { port in await latch.resolvePort(port) }
        )

        return try await withThrowingTaskGroup(of: RunResult?.self) { group in
            // Server task: runs until cancelled.
            group.addTask {
                try await app.run()
                return nil
            }
            // Driver task: wait for bind, fire onBound, await the one callback.
            group.addTask {
                let port = await latch.waitForPort()
                let redirectURI = config.redirectURI(boundPort: port)
                if let onBound { await onBound(redirectURI) }
                let outcome = await latch.waitForOutcome()
                return RunResult(outcome: outcome, boundPort: port, redirectURI: redirectURI)
            }

            // The driver task produces the result; cancel the server once we have it.
            var result: RunResult?
            for try await value in group {
                if let value {
                    result = value
                    group.cancelAll()
                    break
                }
            }
            return result!
        }
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// Classify a callback's query parameters into an outcome.
    ///
    /// `state` is checked first with a constant-time exact comparison; any
    /// mismatch is rejected before `code`/`error` are even considered.
    static func classify(
        query: some Sequence<(key: Substring, value: Substring)>,
        expectedState: String
    ) -> CallbackOutcome {
        var params: [String: String] = [:]
        for (key, value) in query {
            params[String(key)] = String(value)
        }
        // CSRF: the returned state must be present and an exact match.
        guard let returnedState = params["state"],
              ConstantTime.equals(expectedState, returnedState) else {
            return .stateMismatch
        }
        if let error = params["error"] {
            return .providerError(error: error, description: params["error_description"])
        }
        if let code = params["code"], !code.isEmpty {
            return .code(code)
        }
        return .missingParameters
    }

    private static func htmlResponse(for outcome: CallbackOutcome, successHTML: String) -> Response {
        let (status, html): (HTTPResponse.Status, String)
        switch outcome {
        case .code:
            (status, html) = (.ok, successHTML)
        case .stateMismatch:
            (status, html) = (.badRequest, Self.errorHTML("State mismatch — request rejected."))
        case .providerError(let error, let description):
            (status, html) = (.badRequest, Self.errorHTML("Authorization failed: \(error)" + (description.map { " — \($0)" } ?? "")))
        case .missingParameters:
            (status, html) = (.badRequest, Self.errorHTML("Callback was missing the authorization code."))
        }
        var buffer = ByteBuffer()
        buffer.writeString(html)
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
    }

    private static func errorHTML(_ message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <title>swiftoauth</title></head>\
        <body style="font-family:system-ui;margin:3rem">\
        <h1>Authentication error</h1>\
        <p>\(message)</p>\
        </body></html>
        """
    }
}
