// SwiftHarnessCore — Usage accounting and permission diagnostics
//
// `UsageSummary` is the running input/output token tally for a
// session; `estimateTokens(_:)` is the (intentionally cheap)
// whitespace-based estimator used to keep the tally moving when no
// real provider is wired up. The estimator must NEVER return zero —
// that invariant is protected by an upstream regression test and is
// mirrored here in `SwiftHarnessCoreTests`.
//
// `PermissionDenial` is the structured "no" returned by the
// permission policy when a tool invocation is blocked.

import Foundation

// MARK: - UsageSummary

/// Running input / output token tally for a session.
///
/// JSON wire shape uses snake_case keys (`input_tokens`,
/// `output_tokens`) to stay byte-identical to the upstream Rust
/// harness. Default value is both fields = 0.
public struct UsageSummary: Hashable, Sendable, Codable {
    /// Running tally of tokens consumed on the input side
    /// (prompt + system + accumulated transcript).
    public let inputTokens: Int

    /// Running tally of tokens emitted on the output side
    /// (assistant responses + tool-call payloads).
    public let outputTokens: Int

    /// Build a `UsageSummary`. Both counts default to zero.
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Return a new `UsageSummary` with the estimated tokens for
    /// `prompt` and `output` folded into the running tally.
    ///
    /// Mirrors the upstream `UsageSummary::add_turn` behavior: each
    /// side is bumped by `estimateTokens` applied to its text.
    public func addingTurn(prompt: String, output: String) -> UsageSummary {
        UsageSummary(
            inputTokens: self.inputTokens + estimateTokens(prompt),
            outputTokens: self.outputTokens + estimateTokens(output)
        )
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - estimateTokens

/// Cheap whitespace-based token estimator.
///
/// Splits `text` on Unicode whitespace and returns the number of
/// non-empty pieces, with a floor of 1. The floor is load-bearing:
/// callers (notably `UsageSummary.addingTurn`) rely on the estimator
/// never returning zero so that "we did a turn" is always visible in
/// the running tally, even on a completely empty prompt or output.
public func estimateTokens(_ text: String) -> Int {
    // `split(whereSeparator:)` skips runs of separators and never
    // emits empty substrings, so the count is exactly the number of
    // non-empty whitespace-delimited tokens.
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    return max(1, tokens.count)
}

// MARK: - PermissionDenial

/// Structured "no" returned by the permission policy when an
/// attempted tool invocation is blocked.
///
/// JSON wire shape has bare `subject` and `reason` keys; Swift
/// property names already match, so no `CodingKeys` are needed.
public struct PermissionDenial: Hashable, Sendable, Codable {
    /// Human-readable identifier of what was being attempted (e.g.
    /// the tool name plus its arguments rendered to a short string).
    public let subject: String

    /// Human-readable reason the attempt was blocked.
    public let reason: String

    /// Build a `PermissionDenial`.
    public init(subject: String, reason: String) {
        self.subject = subject
        self.reason = reason
    }
}
