// Agent — the turn-scoped orchestrator that drives a Provider through
// a bounded loop, dispatches tool calls, and emits structured events.
//
// Design intent:
//
//   - The agent is an `actor` so concurrent `run(...)` invocations
//     against the same instance serialize cleanly.
//   - The tool boundary is a `Sendable` closure
//     (`ToolDispatcher`) rather than a direct dependency on
//     `SwiftPiTools`. Callers (or the eventual `swiftpi` CLI) wire a
//     concrete dispatcher that consults `ToolRegistry`. This keeps
//     `SwiftPiCore` cycle-free.
//   - Tool recursion is bounded by `maxToolIterations` (default 50,
//     matching upstream). On exceeded, the agent emits `agentEnd`
//     and throws `SwiftPiError.iterationLimitExceeded`.
//   - Capability gating is fail-closed: a `Capabilities` view checks
//     each tool invocation by name; denied tools surface as a
//     `toolResultProduced(... isError: true ...)` event whose body
//     is the canonical denial string, and the loop continues so the
//     model can react.

import Foundation

public actor Agent {
    /// Dispatcher signature: given a tool name and JSONValue input,
    /// produce the textual tool output plus an isError flag. Throws
    /// only for transport-level failures; tool-level failures should
    /// be reported via the returned `(text, isError: true)`.
    public typealias ToolDispatcher = @Sendable (
        _ toolName: String,
        _ input: JSONValue
    ) async throws -> (text: String, isError: Bool)

    /// Capability lookup: returns `true` if the named tool may run.
    /// Defaults to "everything allowed". A real deployment supplies
    /// a fail-closed policy.
    public typealias Capabilities = @Sendable (_ toolName: String) -> Bool

    public let provider: any Provider
    public let dispatcher: ToolDispatcher
    public let capabilities: Capabilities
    public let maxToolIterations: Int
    public let sessionID: String?

    public init(
        provider: any Provider,
        dispatcher: @escaping ToolDispatcher,
        capabilities: @escaping Capabilities = { _ in true },
        maxToolIterations: Int = 50,
        sessionID: String? = nil
    ) {
        self.provider = provider
        self.dispatcher = dispatcher
        self.capabilities = capabilities
        self.maxToolIterations = maxToolIterations
        self.sessionID = sessionID
    }

    /// Run the agent for a single user prompt. The returned stream
    /// emits `AgentEvent` values until the model's `stop_reason` is
    /// anything other than `"tool_use"`, the iteration cap fires,
    /// or the provider errors out.
    ///
    /// The agent does NOT persist the resulting conversation —
    /// callers compose `SwiftPiSession.SessionStore` on top of the
    /// event stream for that.
    public nonisolated func run(
        initialContext: Context,
        options: StreamOptions
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.drive(
                        initialContext: initialContext,
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

    // MARK: - Drive loop

    private func drive(
        initialContext: Context,
        options: StreamOptions,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.agentStart(sessionID: sessionID))
        var context = initialContext
        var turnIndex = 0
        var finalStopReason: String? = nil

        while true {
            if turnIndex >= maxToolIterations {
                continuation.yield(.agentEnd(stopReason: "max_tool_iterations"))
                continuation.finish(throwing: SwiftPiError.iterationLimitExceeded(maxToolIterations))
                return
            }
            continuation.yield(.turnStart(turnIndex: turnIndex))

            // Buffer of tool calls + accumulated text content for
            // building the assistant message at turn end.
            var collectedText: [Int: String] = [:]
            var toolCalls: [(index: Int, id: String, name: String, inputBuilder: JSONInputBuilder)] = []
            var activeBlocks: [Int: BlockKind] = [:]
            var turnStopReason: String? = nil

            let stream = provider.stream(context: context, options: options)
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .messageStart:
                        // metadata-only; nothing to surface here
                        break

                    case .contentBlockStart(let payload):
                        if let kind = BlockKind(from: payload.contentBlock) {
                            activeBlocks[payload.index] = kind
                            if case .toolUse(let id, let name, let input) = kind {
                                toolCalls.append((
                                    index: payload.index,
                                    id: id,
                                    name: name,
                                    inputBuilder: JSONInputBuilder(seed: input)
                                ))
                            }
                        }

                    case .contentBlockDelta(let payload):
                        guard let kind = activeBlocks[payload.index] else { break }
                        switch kind {
                        case .text:
                            if let textDelta = payload.delta.objectValue?["text"]?.stringValue {
                                collectedText[payload.index, default: ""] += textDelta
                                continuation.yield(.textDelta(
                                    turnIndex: turnIndex,
                                    index: payload.index,
                                    text: textDelta
                                ))
                            }
                        case .toolUse:
                            // Streaming JSON deltas for tool_use:
                            // upstream may emit `input_json_delta`
                            // events with `partial_json` strings. We
                            // accumulate but in Phase 6 the
                            // FakeProvider supplies the full input
                            // in the content_block_start payload, so
                            // this is harmless and unexercised.
                            if let i = toolCalls.firstIndex(where: { $0.index == payload.index }),
                               let partial = payload.delta.objectValue?["partial_json"]?.stringValue
                            {
                                toolCalls[i].inputBuilder.appendPartialJSON(partial)
                            }
                        case .thinking:
                            break
                        }

                    case .contentBlockStop:
                        // Block is finalized; nothing to do — we
                        // already buffered.
                        break

                    case .messageDelta(let payload):
                        if let reason = payload.delta.objectValue?["stop_reason"]?.stringValue {
                            turnStopReason = reason
                        }

                    case .messageStop:
                        // Stream is done. Loop body falls through.
                        break

                    case .ping:
                        break

                    case .error(let payload):
                        continuation.yield(.turnEnd(turnIndex: turnIndex, stopReason: "error"))
                        continuation.yield(.agentEnd(stopReason: "error"))
                        continuation.finish(throwing: SwiftPiError.providerRejected(
                            code: nil,
                            message: "\(payload.type): \(payload.message)"
                        ))
                        return
                    }
                }
            } catch {
                continuation.yield(.turnEnd(turnIndex: turnIndex, stopReason: "error"))
                continuation.yield(.agentEnd(stopReason: "error"))
                continuation.finish(throwing: error)
                return
            }

            // Build the assistant message reflecting this turn.
            let assistantBlocks = buildAssistantBlocks(
                activeBlocks: activeBlocks,
                collectedText: collectedText,
                toolCalls: toolCalls
            )
            let assistantMessage = Message(
                id: "assistant_\(turnIndex)",
                role: .assistant,
                content: assistantBlocks,
                parent: context.messages.last?.id
            )
            context = Context(
                system: context.system,
                messages: context.messages + [assistantMessage],
                tools: context.tools
            )

            continuation.yield(.turnEnd(turnIndex: turnIndex, stopReason: turnStopReason))

            // If there are no tool calls, we are done.
            if toolCalls.isEmpty {
                finalStopReason = turnStopReason ?? "end_turn"
                break
            }

            // Otherwise, dispatch each tool, fold results into the
            // user-side context, and start a new turn.
            var toolResultBlocks: [Content] = []
            for call in toolCalls {
                let resolvedInput = call.inputBuilder.build()
                if capabilities(call.name) {
                    do {
                        let (text, isError) = try await dispatcher(call.name, resolvedInput)
                        continuation.yield(.toolUseRequested(
                            turnIndex: turnIndex,
                            id: call.id,
                            name: call.name,
                            input: resolvedInput
                        ))
                        continuation.yield(.toolResultProduced(
                            turnIndex: turnIndex,
                            id: call.id,
                            name: call.name,
                            output: text,
                            isError: isError
                        ))
                        toolResultBlocks.append(.toolResult(
                            toolUseId: call.id,
                            content: [.text(text)],
                            isError: isError
                        ))
                    } catch {
                        let message = "tool transport error: \(error)"
                        continuation.yield(.toolResultProduced(
                            turnIndex: turnIndex,
                            id: call.id,
                            name: call.name,
                            output: message,
                            isError: true
                        ))
                        toolResultBlocks.append(.toolResult(
                            toolUseId: call.id,
                            content: [.text(message)],
                            isError: true
                        ))
                    }
                } else {
                    // Capability denied — fail closed, surface as a
                    // tool result with isError=true.
                    let message = "capability denied: \(call.name)"
                    continuation.yield(.toolUseRequested(
                        turnIndex: turnIndex,
                        id: call.id,
                        name: call.name,
                        input: resolvedInput
                    ))
                    continuation.yield(.toolResultProduced(
                        turnIndex: turnIndex,
                        id: call.id,
                        name: call.name,
                        output: message,
                        isError: true
                    ))
                    toolResultBlocks.append(.toolResult(
                        toolUseId: call.id,
                        content: [.text(message)],
                        isError: true
                    ))
                }
            }

            let toolResultMessage = Message(
                id: "tool_result_\(turnIndex)",
                role: .user,
                content: toolResultBlocks,
                parent: assistantMessage.id
            )
            context = Context(
                system: context.system,
                messages: context.messages + [toolResultMessage],
                tools: context.tools
            )

            turnIndex += 1
        }

        continuation.yield(.agentEnd(stopReason: finalStopReason))
        continuation.finish()
    }

    // MARK: - Internal helpers

    private enum BlockKind {
        case text
        case toolUse(id: String, name: String, input: JSONValue)
        case thinking

        init?(from payload: JSONValue) {
            guard let type = payload.objectValue?["type"]?.stringValue else { return nil }
            switch type {
            case "text":
                self = .text
            case "tool_use":
                guard
                    let id = payload.objectValue?["id"]?.stringValue,
                    let name = payload.objectValue?["name"]?.stringValue
                else { return nil }
                let input = payload.objectValue?["input"] ?? .object([:])
                self = .toolUse(id: id, name: name, input: input)
            case "thinking":
                self = .thinking
            default:
                return nil
            }
        }
    }

    /// Tiny helper to accumulate either a single seed JSON value (from
    /// `content_block_start`) or a stream of `partial_json` string
    /// chunks (from `input_json_delta` events) into a single
    /// JSONValue at end-of-block.
    private struct JSONInputBuilder {
        var seed: JSONValue
        var partials: [String] = []

        mutating func appendPartialJSON(_ chunk: String) {
            partials.append(chunk)
        }

        func build() -> JSONValue {
            guard !partials.isEmpty else { return seed }
            let joined = partials.joined()
            if let data = joined.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
            {
                return decoded
            }
            return seed
        }
    }

    private func buildAssistantBlocks(
        activeBlocks: [Int: BlockKind],
        collectedText: [Int: String],
        toolCalls: [(index: Int, id: String, name: String, inputBuilder: JSONInputBuilder)]
    ) -> [Content] {
        // Re-emit blocks in their original index order.
        var blocks: [Content] = []
        for index in activeBlocks.keys.sorted() {
            guard let kind = activeBlocks[index] else { continue }
            switch kind {
            case .text:
                blocks.append(.text(collectedText[index] ?? ""))
            case .toolUse(let id, let name, _):
                if let call = toolCalls.first(where: { $0.index == index }) {
                    blocks.append(.toolUse(id: id, name: name, input: call.inputBuilder.build()))
                }
            case .thinking:
                // Phase 6 does not surface thinking blocks back through
                // the assistant message; the agent loop treats them as
                // observation-only.
                break
            }
        }
        return blocks
    }
}
