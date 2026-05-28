// Provider — the abstract LLM backend interface.
//
// One method that matters: `stream(context:options:)` returns an
// `AsyncThrowingStream<StreamEvent, Error>` of model output. Phase 6
// ships `FakeProvider` (tape-driven, deterministic, no network) so
// the agent loop is testable without hitting a real API. Phase 7
// ships an Anthropic provider built on `async-http-client`.

import Foundation

public protocol Provider: Sendable {
    /// A short, stable name for the provider (e.g. `"anthropic"`).
    /// Used in logs and event metadata; the agent does not branch on
    /// it.
    var name: String { get }

    /// Begin a streamed completion. The returned stream emits
    /// `StreamEvent` values in the same order the upstream wire
    /// protocol would deliver them; the agent loop is responsible
    /// for interpreting `content_block_*` and `message_*` events.
    ///
    /// Errors raised by the underlying transport are surfaced via
    /// the throwing stream. Recoverable per-event decode errors
    /// (Phase 2's `SSEParser.errors`) are conventionally surfaced as
    /// `StreamEvent.error(...)` values rather than throws.
    func stream(
        context: Context,
        options: StreamOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>
}
