// AnthropicProvider — Provider implementation backed by
// async-http-client streaming the Anthropic Messages API.
//
// Endpoint: POST {baseURL}/v1/messages with `stream: true`.
// Request body matches Anthropic's documented JSON shape.
// Response body is decoded incrementally by SwiftPiStreaming's
// SSEParser; the parser yields `SwiftPiCore.StreamEvent` values that
// match Anthropic's `message_start` / `content_block_*` /
// `message_*` / `ping` / `error` SSE event types.
//
// The provider is intentionally NOT shut down on `deinit`:
// `HTTPClient` requires an explicit async `shutdown()`. Callers
// instantiate one `AnthropicProvider` per agent lifetime and call
// `shutdown()` at the end. The convenience `withProvider(_:body:)`
// helper ensures shutdown even on error paths.

import Foundation
import AsyncHTTPClient
import NIO
import NIOFoundationCompat
import NIOHTTP1
import SwiftPiCore
import SwiftPiStreaming

public final class AnthropicProvider: Provider, @unchecked Sendable {
    public let name: String = "anthropic"
    public let apiKey: String
    public let baseURL: String
    public let anthropicVersion: String
    public let beta: String?
    public let requestTimeoutSeconds: Double
    public let httpClient: HTTPClient

    /// Build a provider against `https://api.anthropic.com` (default)
    /// or any compatible endpoint (test fixture, proxy, self-hosted
    /// gateway). The provider creates and owns an `HTTPClient`; call
    /// `shutdown()` when finished.
    public init(
        apiKey: String,
        baseURL: String = "https://api.anthropic.com",
        anthropicVersion: String = "2023-06-01",
        beta: String? = nil,
        requestTimeoutSeconds: Double = 600
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL.hasSuffix("/")
            ? String(baseURL.dropLast())
            : baseURL
        self.anthropicVersion = anthropicVersion
        self.beta = beta
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    }

    /// Shut down the underlying `HTTPClient`. Safe to call once.
    /// Callers that own a provider for the duration of a process can
    /// also rely on the singleton event loop group's atexit handler,
    /// but explicit shutdown is preferred.
    public func shutdown() async throws {
        try await httpClient.shutdown()
    }

    // MARK: - Provider

    public func stream(
        context: Context,
        options: StreamOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.driveRequest(
                        context: context,
                        options: options,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request lifecycle

    private func driveRequest(
        context: Context,
        options: StreamOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let bodyData = try Self.encodeRequestBody(context: context, options: options)

        var request = HTTPClientRequest(url: "\(baseURL)/v1/messages")
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        request.headers.add(name: "accept", value: "text/event-stream")
        request.headers.add(name: "x-api-key", value: apiKey)
        request.headers.add(name: "anthropic-version", value: anthropicVersion)
        if let beta {
            request.headers.add(name: "anthropic-beta", value: beta)
        }
        request.body = .bytes(ByteBuffer(bytes: Array(bodyData)))

        let response = try await httpClient.execute(
            request,
            timeout: .seconds(Int64(requestTimeoutSeconds))
        )

        // Non-2xx → fail fast; drain a bounded amount of the response
        // body for a useful error message rather than the whole thing.
        guard response.status.code >= 200 && response.status.code < 300 else {
            let bodyText = try await Self.readBoundedBody(response, maxBytes: 4096)
            throw SwiftPiError.providerRejected(
                code: Int(response.status.code),
                message: bodyText.isEmpty
                    ? "Anthropic HTTP \(response.status.code)"
                    : bodyText
            )
        }

        // Hand the streaming body to SSEParser via SSEParser directly
        // (synchronous feed loop, fewer moving parts than the async
        // adapter for this use case).
        var parser = SSEParser()
        for try await chunk in response.body {
            if Task.isCancelled { break }
            let bytes = Array(buffer: chunk)
            let output = parser.feed(bytes)
            for event in output.events {
                continuation.yield(event)
            }
            // SSE-level decode failures are recoverable; surface them
            // as synthesized error events so consumers can decide.
            for error in output.errors {
                continuation.yield(.error(
                    StreamErrorPayload(
                        type: "swiftpi_decode_error",
                        message: error.description
                    )
                ))
            }
        }
        let tail = parser.finish()
        for event in tail.events {
            continuation.yield(event)
        }
        for error in tail.errors {
            continuation.yield(.error(
                StreamErrorPayload(
                    type: "swiftpi_decode_error",
                    message: error.description
                )
            ))
        }
        continuation.finish()
    }

    private static func readBoundedBody(
        _ response: HTTPClientResponse,
        maxBytes: Int
    ) async throws -> String {
        var collected = Data()
        for try await chunk in response.body {
            let bytes = Array(buffer: chunk)
            let remaining = maxBytes - collected.count
            if remaining <= 0 { break }
            collected.append(contentsOf: bytes.prefix(remaining))
            if collected.count >= maxBytes { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    // MARK: - Request body encoding

    /// Encode `Context` + `StreamOptions` into the JSON shape the
    /// Anthropic Messages API expects, using snake_case keys
    /// throughout. We do NOT route through `Context.encode(to:)`
    /// because the wire shape on the request side is a flat object,
    /// distinct from the session entry shape SwiftPiSession persists.
    static func encodeRequestBody(
        context: Context,
        options: StreamOptions
    ) throws -> Data {
        var root: [String: JSONValue] = [
            "model": .string(options.model),
            "max_tokens": .int(options.maxTokens),
            "stream": .bool(true),
        ]
        if let temperature = options.temperature {
            root["temperature"] = .double(temperature)
        }
        if !options.stopSequences.isEmpty {
            root["stop_sequences"] = .array(options.stopSequences.map { .string($0) })
        }
        if let thinking = options.thinking {
            var entry: [String: JSONValue] = [
                "type": .string(thinking.level == .off ? "disabled" : "enabled"),
            ]
            if thinking.level != .off, let budget = thinking.budgetTokens {
                entry["budget_tokens"] = .int(budget)
            }
            root["thinking"] = .object(entry)
        }
        if let system = context.system {
            root["system"] = .string(system)
        }
        if !context.tools.isEmpty {
            let toolJSON = try context.tools.map { def -> JSONValue in
                .object([
                    "name": .string(def.name),
                    "description": .string(def.description),
                    "input_schema": def.inputSchema,
                ])
            }
            root["tools"] = .array(toolJSON)
        }
        // Convert Message values into the wire shape Anthropic expects
        // for the messages array. Each message becomes an object with
        // `role` and `content` (which is an array of content blocks).
        let messageObjects = context.messages.compactMap { message -> JSONValue? in
            // Anthropic's messages array does not include `system` —
            // that lives at the top level.
            guard message.role != .system else { return nil }
            let role: String
            switch message.role {
            case .user:      role = "user"
            case .assistant: role = "assistant"
            case .system:    role = "user"  // unreachable
            }
            // Re-encode each Content block by round-tripping through
            // JSONEncoder/JSONDecoder so snake_case keys land verbatim.
            let blocks = message.content.compactMap { block -> JSONValue? in
                try? Self.contentToJSON(block)
            }
            return .object([
                "role": .string(role),
                "content": .array(blocks),
            ])
        }
        root["messages"] = .array(messageObjects)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(root))
    }

    private static func contentToJSON(_ content: Content) throws -> JSONValue {
        let data = try JSONEncoder().encode(content)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Lifecycle helper

/// Run `body` with a fresh `AnthropicProvider`, shutting it down on
/// every exit path. Recommended for short-lived CLIs and tests.
public func withAnthropicProvider<T: Sendable>(
    apiKey: String,
    baseURL: String = "https://api.anthropic.com",
    anthropicVersion: String = "2023-06-01",
    beta: String? = nil,
    requestTimeoutSeconds: Double = 600,
    body: (AnthropicProvider) async throws -> T
) async throws -> T {
    let provider = AnthropicProvider(
        apiKey: apiKey,
        baseURL: baseURL,
        anthropicVersion: anthropicVersion,
        beta: beta,
        requestTimeoutSeconds: requestTimeoutSeconds
    )
    do {
        let result = try await body(provider)
        try? await provider.shutdown()
        return result
    } catch {
        try? await provider.shutdown()
        throw error
    }
}
