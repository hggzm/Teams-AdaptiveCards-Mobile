// SwiftHarnessSession — Label validation
//
// Labels are user-supplied strings attached to a session for human
// addressing (e.g. `label:my-experiment`). They are trimmed of
// surrounding whitespace; an empty / whitespace-only label is invalid.
// No length cap is enforced at this phase.

import Foundation
import SwiftHarnessCore

/// Normalize a user-supplied label.
///
/// Trims surrounding whitespace. Throws `HarnessError.invalidLabel`
/// when the trimmed result is empty.
public func normalizeLabel(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        throw HarnessError.invalidLabel(raw)
    }
    return trimmed
}
