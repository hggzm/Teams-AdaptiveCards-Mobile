// AsyncSSEStream — adapt the synchronous `SSEParser` to an
// `AsyncThrowingStream<StreamEvent, Error>`, ready for plugging into a
// `Provider` implementation in Phase 7.
//
// Errors policy:
//   - JSON-level decode errors are folded into the parser's
//     `SSEParseOutput.errors` collection. By default this async stream
//     surfaces those as `StreamEvent.error(...)` values so consumers
//     don't have to wire a side channel; set `failOnDecodeError = true`
//     to convert the first such error into a thrown `SwiftPiError`
//     instead.
//   - Upstream byte-source errors are always rethrown.

import Foundation
import SwiftPiCore

public enum AsyncSSEStream {
    /// Build an `AsyncThrowingStream<StreamEvent, Error>` from an
    /// arbitrary async byte source.
    ///
    /// - Parameters:
    ///   - bytes: an async byte source yielding `[UInt8]` chunks.
    ///   - failOnDecodeError: when `true`, the first JSON decode error
    ///     terminates the stream with a thrown error. When `false`
    ///     (the default), decode errors are surfaced as
    ///     `StreamEvent.error(...)` synthesized values with type
    ///     `"swiftpi_decode_error"`.
    public static func make<S: AsyncSequence & Sendable>(
        from bytes: S,
        failOnDecodeError: Bool = false
    ) -> AsyncThrowingStream<StreamEvent, Error> where S.Element == [UInt8] {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await chunk in bytes {
                        let output = parser.feed(chunk)
                        try yield(output, continuation: continuation, failOnDecodeError: failOnDecodeError)
                    }
                    let tail = parser.finish()
                    try yield(tail, continuation: continuation, failOnDecodeError: failOnDecodeError)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func yield(
        _ output: SSEParseOutput,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        failOnDecodeError: Bool
    ) throws {
        for event in output.events {
            continuation.yield(event)
        }
        for error in output.errors {
            if failOnDecodeError {
                throw error
            }
            continuation.yield(
                .error(
                    StreamErrorPayload(
                        type: "swiftpi_decode_error",
                        message: error.description
                    )
                )
            )
        }
    }
}
