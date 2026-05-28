// SwiftPiTools — module documentation namespace.
//
// Phase 4 landed the four non-bash built-ins (`read`, `write`,
// `edit`, `ls`) plus the `Tool` protocol, `ToolOutput`,
// `ToolTruncation` head+tail algorithm, and `ToolRegistry` dispatcher.
//
// Phase 5 adds `BashTool` plus its supporting `ProcessState` one-shot
// latch and `ShellLauncher` configuration struct. The tool spawns a
// platform shell (`cmd.exe /C` on Windows, `/bin/sh -c` elsewhere)
// with the termination-handler-before-run() pattern from
// /memories/swift-foundation-process-linux.md and a one-shot actor
// latch arbitrating between the handler and the timeout task.
//
// Process-tree cleanup (Unix `posix_kill` walk + Windows JobObject)
// remains a known gap: `Foundation.Process.terminate()` only kills
// the direct child. Acceptable for v0.1 short-lived diagnostic use;
// full tree cleanup is a later phase.

import SwiftPiCore

public enum SwiftPiToolsVersion {
    public static let phase: Int = 5
    public static let coreVersion: String = SwiftPiCoreVersion.versionString
}
