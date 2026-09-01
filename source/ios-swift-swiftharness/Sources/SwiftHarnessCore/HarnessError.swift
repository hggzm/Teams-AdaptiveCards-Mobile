// SwiftHarnessCore — Consolidated error type
//
// A single `enum HarnessError: Error, CustomStringConvertible` whose
// cases are the union of the upstream Rust `RuntimeError` variants.
// Each case's `description` reproduces the upstream `#[error("…")]`
// wording verbatim so the CLI's user-facing error messages stay
// byte-identical between the Rust and Swift implementations.
//
// New cases should only be added when an upstream variant is added;
// renames are forbidden because they break the wire contract.

import Foundation

/// All errors thrown by swiftharness library targets.
///
/// `description` matches the upstream Rust harness error wording
/// byte-for-byte. Tests in `SwiftHarnessCoreTests` enforce this.
public enum HarnessError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Filesystem / IO failure surfaced by the persistence layer.
    case io(String)

    /// JSON encode / decode failure surfaced by the persistence layer.
    case serialization(String)

    /// The requested session does not exist.
    case sessionNotFound(String)

    /// A session bundle already exists for the requested identifier.
    case sessionAlreadyExists(String)

    /// A persisted session bundle is malformed or unreadable.
    case invalidBundle(String)

    /// The provided session label fails validation.
    case invalidLabel(String)

    /// More than one session resolves to the provided label.
    case ambiguousLabel(String)

    /// The provided session selector (raw id / `latest` / `label:<name>`)
    /// cannot be parsed.
    case malformedSelector(String)

    /// The session is already unlabeled and cannot be unlabeled again.
    case sessionAlreadyUnlabeled(String)

    /// The session is already labeled and cannot be labeled again
    /// without `retag`.
    case sessionAlreadyLabeled(String)

    /// The session is already pinned.
    case sessionAlreadyPinned(String)

    /// The session is already unpinned.
    case sessionAlreadyUnpinned(String)

    /// The requested transcript turn index is outside the recorded
    /// range.
    case transcriptTurnOutOfRange(String)

    public var description: String {
        switch self {
        case .io(let m):                      return "io error: \(m)"
        case .serialization(let m):           return "serialization error: \(m)"
        case .sessionNotFound(let m):         return "session not found: \(m)"
        case .sessionAlreadyExists(let m):    return "session already exists: \(m)"
        case .invalidBundle(let m):           return "invalid session bundle: \(m)"
        case .invalidLabel(let m):            return "invalid session label: \(m)"
        case .ambiguousLabel(let m):          return "ambiguous session label: \(m)"
        case .malformedSelector(let m):       return "malformed session selector: \(m)"
        case .sessionAlreadyUnlabeled(let m): return "session already unlabeled: \(m)"
        case .sessionAlreadyLabeled(let m):   return "session already labeled: \(m)"
        case .sessionAlreadyPinned(let m):    return "session already pinned: \(m)"
        case .sessionAlreadyUnpinned(let m):  return "session already unpinned: \(m)"
        case .transcriptTurnOutOfRange(let m): return "transcript turn out of range: \(m)"
        }
    }
}
