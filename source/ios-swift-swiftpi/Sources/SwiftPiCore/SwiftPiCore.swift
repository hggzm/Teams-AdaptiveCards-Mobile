// SwiftPiCore — module documentation namespace.
//
// SwiftPiCore exports the shared types (`Role`, `Content`, `Message`,
// `ToolDef`, `Context`, `StreamOptions`, `ThinkingConfig`, `StreamEvent`,
// `JSONValue`, `SwiftPiError`) used by every other swiftpi module.
//
// Stability promise: from v0.1.0 onward, no Phase-2-or-later commit will
// remove or rename a public symbol in this module without bumping the
// minor version. Field additions on existing types are permitted.

/// Version constant for the SwiftPiCore module. Bumped per phase when
/// public surface changes meaningfully. Tests assert this exists so
/// renames don't pass silently.
public enum SwiftPiCoreVersion {
    public static let major = 0
    public static let minor = 1
    public static let patch = 0

    /// Human-readable version string, e.g. `"0.1.0"`.
    public static var versionString: String {
        "\(major).\(minor).\(patch)"
    }
}
