import Foundation

/// A ``ToolchainDriver`` that bridges the in-memory ``VirtualFileSystem`` to the
/// real host filesystem so an *inner* driver which executes on real paths (e.g.
/// ``WasmFrontendDriver`` → `wasmtime`) can build a `nativeBinary` recipe whose
/// sources live in the VFS.
///
/// `NativeBuildBackend` stages a recipe's sources into the VFS and calls
/// `driver.compile(source:to:…)` / `driver.link(objects:to:…)` with **VFS**
/// paths. The wasm frontend, however, reads/writes **real** files. This driver
/// closes that gap: for each call it materializes the VFS inputs to a real work
/// directory, runs the inner driver on the real paths, and reads the produced
/// object/image back into the VFS.
///
/// Pure Foundation (cross-platform). It does no compilation itself — that's the
/// inner driver — so it's fully unit-testable with a disk-writing inner double,
/// no `wasmtime`/SDK required.
public final class MaterializingToolchainDriver: ToolchainDriver {
    public var name: String { "\(inner.name)+materialize" }

    private let inner: ToolchainDriver
    private let vfs: VirtualFileSystem
    private let workDir: String
    private let fileManager: FileManager

    /// - Parameters:
    ///   - inner: the driver that executes on real host paths.
    ///   - vfs: the virtual filesystem holding the recipe's sources / objects.
    ///   - workDir: a real host directory used to stage inputs and collect
    ///     outputs. Created if missing.
    public init(inner: ToolchainDriver, vfs: VirtualFileSystem, workDir: String,
                fileManager: FileManager = .default) {
        self.inner = inner
        self.vfs = vfs
        self.workDir = workDir
        self.fileManager = fileManager
    }

    /// Map a VFS path to a flat, collision-free real path under `workDir` by
    /// replacing path separators. Keeps the file extension (the frontend keys on
    /// `.swift`), so `/a/b/main.swift` → `<workDir>/_a_b_main.swift`.
    func hostPath(forVFSPath vfsPath: String) -> String {
        let flat = vfsPath.replacingOccurrences(of: "/", with: "_")
        return (workDir as NSString).appendingPathComponent(flat)
    }

    private func ensureWorkDir() throws {
        if !fileManager.fileExists(atPath: workDir) {
            try fileManager.createDirectory(
                atPath: workDir, withIntermediateDirectories: true)
        }
    }

    /// Copy a VFS file's bytes to its mapped real path.
    private func materialize(vfsPath: String) throws -> String {
        let host = hostPath(forVFSPath: vfsPath)
        let data = try vfs.readFile(vfsPath)
        try data.write(to: URL(fileURLWithPath: host))
        return host
    }

    /// Read a real file's bytes back into the VFS at `vfsPath`.
    private func collect(hostPath: String, intoVFSPath vfsPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: hostPath))
        try vfs.writeFile(vfsPath, data: data)
    }

    // MARK: ToolchainDriver

    public func compile(source: String, to object: String, target: TargetPlatform,
                        sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic] {
        try ensureWorkDir()
        let hostSource = try materialize(vfsPath: source)
        let hostObject = hostPath(forVFSPath: object)
        // The inner driver writes the object to the real path.
        let diags = try inner.compile(
            source: hostSource, to: hostObject, target: target,
            sdkPath: sdkPath, extraArguments: extraArguments
        )
        guard fileManager.fileExists(atPath: hostObject) else {
            throw ToolchainError.compileFailed(
                source: source,
                diagnostics: diags + [ToolchainDiagnostic(
                    severity: .error,
                    message: "inner driver reported success but produced no object at \(hostObject)",
                    file: source)]
            )
        }
        try collect(hostPath: hostObject, intoVFSPath: object)
        return diags
    }

    public func link(objects: [String], to image: String, target: TargetPlatform,
                     sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic] {
        try ensureWorkDir()
        let hostObjects = try objects.map { try materialize(vfsPath: $0) }
        let hostImage = hostPath(forVFSPath: image)
        let diags = try inner.link(
            objects: hostObjects, to: hostImage, target: target,
            sdkPath: sdkPath, extraArguments: extraArguments
        )
        guard fileManager.fileExists(atPath: hostImage) else {
            throw ToolchainError.linkFailed(
                image: image,
                diagnostics: diags + [ToolchainDiagnostic(
                    severity: .error,
                    message: "inner driver reported success but produced no image at \(hostImage)",
                    file: image)]
            )
        }
        try collect(hostPath: hostImage, intoVFSPath: image)
        return diags
    }
}
