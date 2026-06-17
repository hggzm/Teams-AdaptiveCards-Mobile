import Foundation

/// Where a package is destined to run. The engine never assumes a single
/// target: the same recipe can be built for the desktop *host* (so the catalog
/// and pipeline are exercisable here and now) and later cross-built for the iOS
/// sandbox. iOS packaging is deliberately the last mile — everything is
/// abstracted around it until then.
public enum TargetPlatform: String, Equatable, CaseIterable {
    case host          // the machine running swiftbox (macOS / Linux / Windows / WSL)
    case iosArm64      // on-device iOS / iPadOS (deferred backend)
    case iosSimulator  // iOS simulator
}

/// What kind of artifact a recipe produces — this decides which backend can
/// build it and where.
public enum PackageKind: String, Equatable {
    /// Pure script/data/config; no compiled code. Buildable anywhere, today.
    case interpreted
    /// Needs the Perl runtime package.
    case perl
    /// Needs the Python runtime package.
    case python
    /// Compiled C/C++/native code; needs a cross toolchain. For iOS this is
    /// deferred to the native LiveProcess backend / cross-build phase.
    case nativeBinary
}

/// A single file a package installs, relative to `$PREFIX`.
public struct BuildArtifact: Equatable {
    public var path: String        // e.g. "bin/welcome" or "etc/motd"
    public var contents: String
    public var executable: Bool

    public init(path: String, contents: String, executable: Bool = false) {
        self.path = path
        self.contents = contents
        self.executable = executable
    }
}

/// Parsed metadata from a Termux-style `build.sh` (the `TERMUX_PKG_*` fields),
/// plus the bits swiftbox adds. This is the factual catalog record for a
/// package — the thing we systematically work through when porting to iOS.
public struct RecipeMetadata: Equatable {
    public var name: String
    public var version: SemanticVersion
    public var rawVersion: String
    public var revision: Int
    public var homepage: String?
    public var summary: String
    public var license: String?
    public var maintainer: String?
    public var dependencies: [String]
    public var sourceURL: String?
    public var sha256: String?
    public var platformIndependent: Bool
    public var buildInSrc: Bool
    public var hasCustomBuildSteps: Bool

    public init(
        name: String,
        version: SemanticVersion = SemanticVersion(0),
        rawVersion: String = "0",
        revision: Int = 0,
        homepage: String? = nil,
        summary: String = "",
        license: String? = nil,
        maintainer: String? = nil,
        dependencies: [String] = [],
        sourceURL: String? = nil,
        sha256: String? = nil,
        platformIndependent: Bool = false,
        buildInSrc: Bool = false,
        hasCustomBuildSteps: Bool = false
    ) {
        self.name = name
        self.version = version
        self.rawVersion = rawVersion
        self.revision = revision
        self.homepage = homepage
        self.summary = summary
        self.license = license
        self.maintainer = maintainer
        self.dependencies = dependencies
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.platformIndependent = platformIndependent
        self.buildInSrc = buildInSrc
        self.hasCustomBuildSteps = hasCustomBuildSteps
    }
}

/// A source file a compiled (`nativeBinary`) package builds from. Carried in
/// the recipe so an on-device ``ToolchainDriver`` can compile it without the
/// network: `path` is staged into the build dir, `contents` is the source text.
public struct SourceFile: Equatable {
    public var path: String        // e.g. "src/main.swift" or "hello.c"
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }

    /// True for a Swift source (drives `-emit-object` vs C/clang).
    public var isSwift: Bool { path.hasSuffix(".swift") }
}

/// A buildable package: metadata + how to realize it + what it installs.
public struct BuildRecipe: Equatable {
    public var metadata: RecipeMetadata
    public var kind: PackageKind
    public var artifacts: [BuildArtifact]
    /// Optional build commands run through the interpreter to *produce* the
    /// package's files (the swiftbox analogue of Termux's `termux_step_*`
    /// functions). When present, the build runs these in a scratch build
    /// directory and collects whatever they install under `$PREFIX` as the
    /// package's artifacts. When empty, ``artifacts`` are staged verbatim.
    public var buildSteps: [String]
    /// Source files for a compiled (`nativeBinary`) package. When present and a
    /// ``ToolchainDriver`` is available, the native build backend compiles these
    /// to objects, links an image, and installs it as `bin/<name>`.
    public var sources: [SourceFile]
    /// The installed image path (relative to `$PREFIX`) a compiled build
    /// produces. Defaults to `bin/<name>`.
    public var installPath: String?
    /// Where this recipe came from, for provenance in the catalog.
    public var origin: String

    public init(
        metadata: RecipeMetadata,
        kind: PackageKind,
        artifacts: [BuildArtifact] = [],
        buildSteps: [String] = [],
        sources: [SourceFile] = [],
        installPath: String? = nil,
        origin: String = "termux"
    ) {
        self.metadata = metadata
        self.kind = kind
        self.artifacts = artifacts
        self.buildSteps = buildSteps
        self.sources = sources
        self.installPath = installPath
        self.origin = origin
    }

    public var name: String { metadata.name }

    /// Project the recipe onto the lighter ``PackageManifest`` used by the
    /// resolver and `pkg`.
    public var manifest: PackageManifest {
        PackageManifest(
            name: metadata.name,
            version: metadata.version,
            summary: metadata.summary,
            dependencies: metadata.dependencies,
            homepage: metadata.homepage,
            arch: kind == .interpreted ? "all" : "ios-arm64"
        )
    }
}
