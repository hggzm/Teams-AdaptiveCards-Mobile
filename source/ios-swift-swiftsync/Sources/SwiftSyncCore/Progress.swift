/// A live snapshot of transfer progress, suitable for rendering a one-line
/// status with an ETA. All byte counts are in bytes.
public struct ProgressInfo: Sendable, Equatable {
    /// Name (relative path) of the file currently being transferred.
    public var currentFile: String
    /// Bytes transferred so far for the current file.
    public var fileDone: Int
    /// Total size of the current file in bytes.
    public var fileSize: Int
    /// Bytes transferred across all files since the run started.
    public var totalDone: Int
    /// Estimated total size of the whole transfer in bytes.
    public var totalSize: Int
    /// 1-based index of the current file among all files to transfer.
    public var index: Int
    /// Total number of files to transfer.
    public var numFiles: Int
    /// Estimated time remaining, in whole seconds.
    public var eta: Int

    public init(
        currentFile: String = "",
        fileDone: Int = 0,
        fileSize: Int = 0,
        totalDone: Int = 0,
        totalSize: Int = 0,
        index: Int = 0,
        numFiles: Int = 0,
        eta: Int = 0
    ) {
        self.currentFile = currentFile
        self.fileDone = fileDone
        self.fileSize = fileSize
        self.totalDone = totalDone
        self.totalSize = totalSize
        self.index = index
        self.numFiles = numFiles
        self.eta = eta
    }
}

/// Messages emitted by the sync pipeline toward the progress reporter.
///
/// In the worker model these flow over an `AsyncStream` from the syncer to the
/// progress reporter, keeping all rendering off the hot copy path.
public enum ProgressMessage: Sendable, Equatable {
    /// A transfer from `source` to `destination` has begun.
    case started(source: String, destination: String)
    /// The work to be done is known: `numFiles` files totalling `totalBytes`
    /// bytes will actually be copied. Drives the percent and ETA denominators.
    case planned(numFiles: Int, totalBytes: Int)
    /// A new file named `name` (of `size` bytes) is being transferred.
    case fileStarted(name: String, size: Int)
    /// `bytes` more bytes were copied for the current file.
    case progressed(bytes: Int)
    /// The current file finished transferring.
    case fileDone
    /// The whole transfer is complete.
    case done
}
