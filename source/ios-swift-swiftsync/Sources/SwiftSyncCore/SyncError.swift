/// Every way a sync can fail.
///
/// Mirrors the single `anyhow`-style error surface of the upstream tool: one
/// error type with a case per failure mode, each carrying enough context to
/// render a single useful line.
public enum SyncError: Error, Equatable, Sendable, CustomStringConvertible {
    case sourceDoesNotExist(path: String)
    case notADirectory(path: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case createDirectoryFailed(path: String, reason: String)
    case metadataFailed(path: String, reason: String)
    case copyFailed(entry: String, reason: String)
    case errorListWriteFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .sourceDoesNotExist(path):
            return "source does not exist: \(path)"
        case let .notADirectory(path):
            return "not a directory: \(path)"
        case let .readFailed(path, reason):
            return "could not read '\(path)': \(reason)"
        case let .writeFailed(path, reason):
            return "could not write '\(path)': \(reason)"
        case let .createDirectoryFailed(path, reason):
            return "could not create directory '\(path)': \(reason)"
        case let .metadataFailed(path, reason):
            return "could not read metadata for '\(path)': \(reason)"
        case let .copyFailed(entry, reason):
            return "could not copy '\(entry)': \(reason)"
        case let .errorListWriteFailed(path, reason):
            return "could not write error list '\(path)': \(reason)"
        }
    }
}
