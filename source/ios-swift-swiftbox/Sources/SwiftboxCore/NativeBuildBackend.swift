import Foundation

/// Builds compiled (`nativeBinary`) recipes by driving a ``ToolchainDriver``:
/// compile each source to an object, link the objects into an image, and stage
/// it into `$PREFIX`.
///
/// This is the build backend for the **on-device** path. On the desktop there
/// is no native iOS toolchain, so the host build leaves `nativeBinary` recipes
/// `deferred`. On an iPhone (inside the emexDE / LiveProcess runtime) a
/// `CoreCompilerDriver` is injected and the same recipes compile for real —
/// without the broken wasm cross-compiler. Sources travel inside the recipe, so
/// no network is needed.
public final class NativeBuildBackend: BuildBackend {
    public let target: TargetPlatform
    private let driver: ToolchainDriver
    private let sdkPath: String?

    public init(target: TargetPlatform = .iosArm64, driver: ToolchainDriver, sdkPath: String? = nil) {
        self.target = target
        self.driver = driver
        self.sdkPath = sdkPath
    }

    public func canBuild(_ recipe: BuildRecipe) -> Bool {
        recipe.kind == .nativeBinary && !recipe.sources.isEmpty
    }

    public func build(_ recipe: BuildRecipe, into vfs: VirtualFileSystem, prefix: String) -> BuildReport {
        func report(_ status: BuildStatus) -> BuildReport {
            BuildReport(package: recipe.name, target: target, status: status)
        }

        guard recipe.kind == .nativeBinary else {
            return report(.deferred(reason: "not a compiled package"))
        }
        guard !recipe.sources.isEmpty else {
            return report(.deferred(reason: "compiled package carries no sources"))
        }

        let buildDir = "\(prefix)/tmp/build/\(recipe.name)"
        _ = try? vfs.makeDirectory(buildDir)

        // Incremental build: a content-hash manifest records the source SHA-256
        // last compiled to each object. A source is recompiled only when its
        // contents changed or its object is missing — the content-addressed
        // analogue of emexDE's `skipCompileForInputFile` (which uses mtimes).
        let manifestPath = "\(buildDir)/.sbox-build-manifest"
        let manifest = BuildManifest.load(from: manifestPath, in: vfs)
        var newManifest = BuildManifest()
        var objects: [String] = []
        var anyCompiled = false

        for source in recipe.sources {
            let srcPath = "\(buildDir)/\(source.path)"
            let objPath = srcPath + ".o"
            let hash = SHA256.hexDigest(source.contents)
            newManifest.set(source: source.path, hash: hash)

            // Skip recompilation when the source is unchanged and the object
            // already exists.
            if manifest.hash(forSource: source.path) == hash, vfs.isFile(objPath) {
                objects.append(objPath)
                continue
            }

            do {
                try vfs.writeFile(srcPath, string: source.contents)
            } catch {
                return report(.failed(reason: "could not stage source \(source.path)"))
            }
            do {
                let diags = try driver.compile(
                    source: srcPath, to: objPath, target: target,
                    sdkPath: sdkPath, extraArguments: []
                )
                if let firstError = diags.first(where: { $0.isError }) {
                    return report(.failed(reason: "compile error in \(source.path): \(firstError.message)"))
                }
                objects.append(objPath)
                anyCompiled = true
            } catch let ToolchainError.compileFailed(_, diagnostics) {
                let msg = diagnostics.first(where: { $0.isError })?.message ?? "compile failed"
                return report(.failed(reason: "\(source.path): \(msg)"))
            } catch {
                return report(.failed(reason: "compile failed for \(source.path)"))
            }
        }

        // Link only when an object was (re)built or the image is missing.
        let installRel = recipe.installPath ?? "bin/\(recipe.name)"
        let imagePath = "\(prefix)/\(installRel)"
        if anyCompiled || !vfs.isFile(imagePath) {
            _ = try? vfs.makeDirectory((imagePath as NSString).deletingLastPathComponent)
            do {
                let diags = try driver.link(
                    objects: objects, to: imagePath, target: target,
                    sdkPath: sdkPath, extraArguments: []
                )
                if let firstError = diags.first(where: { $0.isError }) {
                    return report(.failed(reason: "link error: \(firstError.message)"))
                }
            } catch let ToolchainError.linkFailed(_, diagnostics) {
                let msg = diagnostics.first(where: { $0.isError })?.message ?? "link failed"
                return report(.failed(reason: "link: \(msg)"))
            } catch {
                return report(.failed(reason: "link failed"))
            }
        }

        // Persist the manifest and record the installed file in the package db.
        newManifest.save(to: manifestPath, in: vfs)
        let dbPath = "\(prefix)/var/lib/swiftbox/\(recipe.name).list"
        try? vfs.writeFile(dbPath, string: installRel + "\n")
        return report(.built(artifacts: [installRel]))
    }
}

/// A content-hash manifest mapping a source path to the SHA-256 it was last
/// compiled at, used to skip unchanged sources on rebuild. Persisted as a small
/// `path\thash` text file in the build directory.
struct BuildManifest {
    private var hashes: [String: String] = [:]

    func hash(forSource source: String) -> String? { hashes[source] }
    mutating func set(source: String, hash: String) { hashes[source] = hash }

    static func load(from path: String, in vfs: VirtualFileSystem) -> BuildManifest {
        var m = BuildManifest()
        guard let text = try? vfs.readString(path) else { return m }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { m.hashes[String(parts[0])] = String(parts[1]) }
        }
        return m
    }

    func save(to path: String, in vfs: VirtualFileSystem) {
        let text = hashes.sorted { $0.key < $1.key }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n")
        try? vfs.writeFile(path, string: text + "\n")
    }
}

