// SwiftPiSession — module documentation namespace.
//
// Phase 3 lands the real implementation:
//   - `SessionEntry`: typed enum over the four JSONL v3 row shapes
//     (`session` header, `message`, `model_change`, `compaction`).
//   - `JSONLReader` / `JSONLWriter`: line-oriented decode/encode with
//     LF/CRLF tolerance on read and deterministic sorted-key output on
//     write.
//   - `SessionTree`: pure functions to walk parent pointers from a
//     tip back to the root, list leaves, and project the conversation
//     out of an interleaved entry list.
//   - `SessionStore`: actor wrapping a single session file on disk,
//     with write-to-temp + move atomic-save (the workaround for the
//     Windows swift-corelibs-foundation `FileManager.replaceItemAt`
//     gap; see /memories/swift-foundation-filemanager-windows.md).
//
// Compaction is intentionally a Phase 6 deliverable: the row shape is
// present so v3 files containing compaction entries round-trip today,
// but the algorithm that decides cut points and writes those rows
// lands once the agent loop knows its token budget.

import SwiftPiCore

public enum SwiftPiSessionVersion {
    public static let phase: Int = 3
    public static let coreVersion: String = SwiftPiCoreVersion.versionString
}
