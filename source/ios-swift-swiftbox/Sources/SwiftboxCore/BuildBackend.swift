import Foundation

/// The outcome of attempting to build one package.
public enum BuildStatus: Equatable {
    /// Built and its artifacts staged into `$PREFIX`.
    case built(artifacts: [String])
    /// Cannot be built by this backend yet; carries the reason (the porting
    /// backlog message). Not a failure — an honest "later".
    case deferred(reason: String)
    /// A real failure (e.g. a recipe that should have built but errored).
    case failed(reason: String)

    public var isBuilt: Bool { if case .built = self { return true }; return false }
    public var isDeferred: Bool { if case .deferred = self { return true }; return false }
}

/// A per-package build report.
public struct BuildReport: Equatable {
    public var package: String
    public var target: TargetPlatform
    public var status: BuildStatus

    public init(package: String, target: TargetPlatform, status: BuildStatus) {
        self.package = package
        self.target = target
        self.status = status
    }
}

/// A pluggable build strategy for a given ``TargetPlatform``. Keeping this a
/// protocol is the whole point: the host backend lets us exercise the catalog
/// and pipeline today, while the iOS backend is filled in last without touching
/// any of the surrounding machinery.
public protocol BuildBackend: AnyObject {
    var target: TargetPlatform { get }
    func canBuild(_ recipe: BuildRecipe) -> Bool
    func build(_ recipe: BuildRecipe, into vfs: VirtualFileSystem, prefix: String) -> BuildReport
}

/// Builds packages for the machine running swiftbox (macOS / Linux / Windows /
/// WSL). It can fully realize ``PackageKind/interpreted`` recipes that declare
/// artifacts by staging those files into `$PREFIX`. Anything needing a native
/// toolchain or a language runtime we don't yet ship is reported as
/// `deferred` — the actionable iOS-porting backlog.
public final class HostBuildBackend: BuildBackend {
    public let target: TargetPlatform = .host

    /// Optional source provider. When a recipe declares a `TERMUX_PKG_SHA256`
    /// and the provider can supply its bytes, the build verifies integrity
    /// before staging and fails on a checksum mismatch.
    public var sourceProvider: SourceProvider?

    public init(sourceProvider: SourceProvider? = nil) {
        self.sourceProvider = sourceProvider
    }

    public func canBuild(_ recipe: BuildRecipe) -> Bool {
        recipe.kind == .interpreted && (!recipe.artifacts.isEmpty || !recipe.buildSteps.isEmpty)
    }

    public func build(_ recipe: BuildRecipe, into vfs: VirtualFileSystem, prefix: String) -> BuildReport {
        func report(_ status: BuildStatus) -> BuildReport {
            BuildReport(package: recipe.name, target: target, status: status)
        }

        // Verify source integrity if we have both a checksum and the bytes.
        if let provider = sourceProvider, let sha = recipe.metadata.sha256, !sha.isEmpty {
            if let data = try? provider.fetch(recipe) {
                do {
                    try SourceVerifier.verify(data, for: recipe)
                } catch let SourceError.checksumMismatch(_, expected, actual) {
                    return report(.failed(reason: "checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"))
                } catch {
                    return report(.failed(reason: "source verification failed"))
                }
            }
        }

        // Scripted build: run the recipe's build steps in a scratch directory
        // and collect whatever they install under `$PREFIX`.
        if recipe.kind == .interpreted && !recipe.buildSteps.isEmpty {
            return runScriptedBuild(recipe, into: vfs, prefix: prefix)
        }

        switch recipe.kind {
        case .interpreted where !recipe.artifacts.isEmpty:
            var staged: [String] = []
            for artifact in recipe.artifacts {
                let dest = prefix + "/" + artifact.path
                do {
                    try vfs.writeFile(dest, string: artifact.contents)
                    staged.append(artifact.path)
                } catch {
                    return report(.failed(reason: "could not stage \(artifact.path)"))
                }
            }
            recordInstalledFiles(staged, for: recipe.name, into: vfs, prefix: prefix)
            return report(.built(artifacts: staged))

        case .interpreted:
            return report(.deferred(reason: "interpreted package declares no host artifacts"))

        case .perl:
            return report(.deferred(reason: "needs the 'perl' runtime package (not yet ported)"))

        case .python:
            return report(.deferred(reason: "needs the 'python' runtime package (not yet ported)"))

        case .nativeBinary:
            return report(.deferred(reason: "needs a native cross toolchain / iOS build (deferred)"))
        }
    }

    /// Record the file list under the package database so `pkg` can report and
    /// later remove the package.
    private func recordInstalledFiles(_ files: [String], for name: String, into vfs: VirtualFileSystem, prefix: String) {
        let dbPath = "\(prefix)/var/lib/swiftbox/\(name).list"
        try? vfs.writeFile(dbPath, string: files.joined(separator: "\n") + "\n")
    }

    /// Run a recipe's build steps in a scratch build directory and treat any
    /// files they create under `$PREFIX` (outside the build directory) as the
    /// package's artifacts.
    private func runScriptedBuild(_ recipe: BuildRecipe, into vfs: VirtualFileSystem, prefix: String) -> BuildReport {
        func report(_ status: BuildStatus) -> BuildReport {
            BuildReport(package: recipe.name, target: target, status: status)
        }

        let buildDir = "\(prefix)/tmp/build/\(recipe.name)"
        _ = try? vfs.makeDirectory(buildDir)

        func filesUnderPrefix() -> Set<String> {
            let entries = (try? vfs.walk(prefix)) ?? []
            return Set(entries.filter { !$0.isDirectory }.map(\.path))
        }
        let before = filesUnderPrefix()

        // A dedicated build shell scoped to the build directory, with the usual
        // package build environment variables exported.
        let buildShell = Shell(
            vfs: vfs,
            repository: PackageRepository(),
            environment: [
                "PREFIX": prefix,
                "BUILD_DIR": buildDir,
                "PKG_NAME": recipe.name,
                "PKG_VERSION": recipe.metadata.rawVersion,
            ],
            cwd: buildDir
        )
        // Build steps run with abort-on-error semantics (like `set -e`): the
        // first failing step fails the whole build.
        for step in recipe.buildSteps {
            let stepResult = buildShell.run(step)
            if stepResult.exitCode != 0 {
                let detail = stepResult.stderr.split(separator: "\n").last.map(String.init)
                    ?? "step exited \(stepResult.exitCode)"
                return report(.failed(reason: "build step failed: \(detail)"))
            }
        }

        let after = filesUnderPrefix()
        let produced = after.subtracting(before)
            .filter { !$0.hasPrefix(buildDir + "/") && $0 != buildDir }
            .filter { !$0.hasSuffix(".list") }   // ignore package db entries
            .sorted()
        guard !produced.isEmpty else {
            return report(.failed(reason: "build produced no files under $PREFIX"))
        }
        let staged = produced.map { String($0.dropFirst(prefix.count + 1)) }
        recordInstalledFiles(staged, for: recipe.name, into: vfs, prefix: prefix)
        return report(.built(artifacts: staged))
    }
}

/// Placeholder backend for on-device iOS / iPadOS. Intentionally builds nothing
/// yet: it records that a package is destined for iOS so the rest of the system
/// can plan around it. The real implementation (cross-build + LiveProcess
/// packaging + signing) is the last milestone on the roadmap.
public final class IOSBuildBackend: BuildBackend {
    public let target: TargetPlatform
    public init(target: TargetPlatform = .iosArm64) { self.target = target }

    public func canBuild(_ recipe: BuildRecipe) -> Bool { false }

    public func build(_ recipe: BuildRecipe, into vfs: VirtualFileSystem, prefix: String) -> BuildReport {
        BuildReport(
            package: recipe.name,
            target: target,
            status: .deferred(reason: "iOS packaging not yet implemented (final roadmap phase)")
        )
    }
}
