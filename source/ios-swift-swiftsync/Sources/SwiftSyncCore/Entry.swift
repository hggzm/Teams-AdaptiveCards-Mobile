import Foundation

/// The kind of filesystem object an ``Entry`` refers to.
public enum EntryKind: Sendable, Equatable {
    case file
    case directory
    case symlink
}

/// A single source/destination pair discovered while walking the source tree,
/// together with the source-side metadata needed to make a copy decision.
///
/// `Entry` is a pure value type: it holds no open file handles and performs no
/// I/O, so it is safe to pass across actor boundaries.
public struct Entry: Sendable, Equatable {
    /// Path of this entry relative to the sync root, using `/` separators.
    /// Doubles as the human-readable description shown in progress output.
    public var relativePath: String

    /// Absolute location of the entry under the source root.
    public var source: URL

    /// Absolute location the entry should occupy under the destination root.
    public var destination: URL

    /// Whether the entry is a file, directory, or symlink.
    public var kind: EntryKind

    /// Size of the source entry in bytes. Zero for directories.
    public var size: Int64

    /// Modification time of the source entry, if known.
    public var modificationDate: Date?

    public init(
        relativePath: String,
        source: URL,
        destination: URL,
        kind: EntryKind,
        size: Int64,
        modificationDate: Date?
    ) {
        self.relativePath = relativePath
        self.source = source
        self.destination = destination
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
    }

    public var isFile: Bool { kind == .file }
    public var isDirectory: Bool { kind == .directory }
    public var isSymlink: Bool { kind == .symlink }
}
