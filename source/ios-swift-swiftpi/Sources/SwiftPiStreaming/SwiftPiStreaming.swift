// SwiftPiStreaming — module documentation namespace.
//
// Phase 2 lands the real implementation: a byte-state-machine SSE
// parser (`SSEParser` + `SSELineSplitter`) and an `AsyncSSEStream`
// factory that wraps any async byte source. See the type-level
// documentation in `SSEParser.swift` and `SSELineSplitter.swift`.
//
// Stability promise mirrors `SwiftPiCore`: from v0.1.0 onward, no
// later-phase commit removes or renames a public symbol from this
// module without a minor version bump.

import SwiftPiCore

public enum SwiftPiStreamingVersion {
    public static let phase: Int = 2
    public static let coreVersion: String = SwiftPiCoreVersion.versionString
}
