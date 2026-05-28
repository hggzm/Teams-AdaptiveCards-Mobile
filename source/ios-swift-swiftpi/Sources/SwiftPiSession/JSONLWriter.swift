// JSONLWriter — encode a list of session entries into JSONL bytes.
//
// One JSON document per line, terminated by `\n`. Field ordering inside
// each document is sorted (via `.sortedKeys`) so that two runs of
// `swiftpi` over the same data produce byte-identical files — that
// stability matters for diff-friendly review and for cross-validating
// against upstream session captures.

import Foundation
import SwiftPiCore

public enum JSONLWriter {
    /// Encode `entries` into JSONL bytes. Each entry serializes onto its
    /// own line; the result always ends with a trailing `\n` so callers
    /// can append a follow-up entry without re-reading the file.
    public static func encode(_ entries: [SessionEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        output.reserveCapacity(entries.count * 256)
        for entry in entries {
            do {
                let line = try encoder.encode(entry)
                output.append(line)
                output.append(0x0A)  // LF
            } catch {
                throw SwiftPiError.malformedJSON(
                    "encoding session entry failed: \(error.localizedDescription)"
                )
            }
        }
        return output
    }

    /// Encode a single entry into a single JSONL line including the
    /// trailing newline. Used by `SessionStore.append(_:)` so we don't
    /// pay for a full re-encode of the existing transcript on every
    /// append.
    public static func encodeLine(_ entry: SessionEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            return line
        } catch {
            throw SwiftPiError.malformedJSON(
                "encoding session entry failed: \(error.localizedDescription)"
            )
        }
    }
}
