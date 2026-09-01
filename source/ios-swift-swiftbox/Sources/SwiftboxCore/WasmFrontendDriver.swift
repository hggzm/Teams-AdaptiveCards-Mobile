import Foundation

/// The result of one wasm `swift-frontend` invocation.
public struct WasmFrontendResult: Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Executes the wasm-hosted `swift-frontend` (from `hggz/swift-wasm`) with a
/// given argument vector.
///
/// The invocation is injected so the *argv contract* — which flags swiftbox
/// passes for each target/SDK mode — is unit-tested headlessly on any host,
/// while a real runner shells out to `wasmtime` off-band (see `ios/`). This
/// keeps the cross-platform `swift test` gate hermetic: no wasmtime, no SDK, no
/// WSL required to verify the driver.
public protocol WasmFrontendRunner: AnyObject {
    func run(arguments: [String]) throws -> WasmFrontendResult
}

/// Whether a given module-import surface is usable through the currently-wired
/// wasm frontend. Captures *known limitations* as data so they are queryable in
/// code (and so enabling a fixed capability later is a single change).
public enum ModuleSupport: Equatable {
    case supported
    /// Not usable yet. `reason` explains why; `tracking` points at the issue
    /// where the toolchain fix is being worked.
    case blocked(reason: String, tracking: String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }
}

/// A ``ToolchainDriver`` over the **Mac-free wasm cross-compiler** (validated
/// `hggz/swift-wasm` release `ios-xc-toolchain-v3`). It builds the exact
/// `swift-frontend` argument vector swiftbox uses to emit `arm64-apple-ios`
/// Mach-O objects and interprets the result; a ``WasmFrontendRunner`` performs
/// the actual execution.
///
/// **Capability matrix (v3), captured as data:**
/// - SDK-free codegen (`-parse-stdlib`) — ✅ supported.
/// - Core standard library (`import Swift`, `-sdk`) — ✅ supported (v3 fixup S22
///   forces the implicit interface rebuild to `-Onone` on wasm32, sidestepping
///   the SIL-optimizer heap overrun).
/// - Foundation / ObjC modules (`import Foundation`) — ⛔️ **blocked**: the
///   frontend does not expose its clang builtin headers (`stdarg.h`, …) on a
///   `-resource-dir`, so building the SDK's `Darwin` ObjC module fails. Tracked
///   on the toolchain issue. To **enable later** once the toolchain ships the
///   fix: set ``resourceDir`` to the frontend's clang builtin-include dir and
///   flip ``foundationSupport`` to `.supported` — the driver then adds
///   `-resource-dir` automatically. ``ios/smoke-foundation.sh`` auto-detects the
///   fix and flips to PASS.
///
/// Linking is **not** this driver's job: the wasm frontend emits objects; an
/// image is produced by a separate `ld64.lld` + `ldid` step. `link` therefore
/// reports an explanatory error rather than pretending to succeed.
public final class WasmFrontendDriver: ToolchainDriver {
    public let name = "wasm-xc"
    private let runner: WasmFrontendRunner

    /// iOS deployment version baked into the target triple. Defaults to the
    /// version of the staged free SDK (`iPhoneOS16.5`).
    public var iosDeploymentTarget: String

    /// Path passed to `-sdk`'s companion `-resource-dir` — the compiler's own
    /// clang builtin headers. Required only for ObjC-module imports
    /// (Foundation/Darwin); the SDK-free and core-stdlib paths don't need it.
    public var resourceDir: String?

    /// Optional persistent module cache (`-module-cache-path`). Reusing it
    /// across runs avoids re-rebuilding the SDK's overlay interfaces.
    public var moduleCachePath: String?

    // MARK: Capability matrix (queryable; enabling a fixed capability is a flip)

    public var sdkFreeSupport: ModuleSupport = .supported
    public var coreStdlibSupport: ModuleSupport = .supported
    public var foundationSupport: ModuleSupport = .blocked(
        reason: "the wasm frontend's LLVM-21 clang builtin headers are now shipped "
            + "(clang-builtin-headers-llvm21, pass via resourceDir), but a full "
            + "import Foundation still needs the transitive clang-module closure "
            + "(Darwin -> ptrcheck -> _Builtin_stddef -> …, plus SwiftShims) and the "
            + "implicit module-build path to receive -resource-dir; the WASI PCM "
            + "atomic-rename limitation also applies",
        tracking: "hggz/swift-wasm#1"
    )

    public init(runner: WasmFrontendRunner, iosDeploymentTarget: String = "16.5",
                resourceDir: String? = nil, moduleCachePath: String? = nil) {
        self.runner = runner
        self.iosDeploymentTarget = iosDeploymentTarget
        self.resourceDir = resourceDir
        self.moduleCachePath = moduleCachePath
    }

    // MARK: Capability queries

    /// The support status for importing `module` through this frontend. User /
    /// SwiftPM modules go through the core-stdlib path.
    public func support(forImporting module: String) -> ModuleSupport {
        switch module {
        case "Foundation", "Darwin", "ObjectiveC", "Dispatch", "CoreFoundation",
             "CoreGraphics", "UIKit", "QuartzCore":
            return foundationSupport
        case "Swift", "_Concurrency", "_StringProcessing", "Builtin":
            return coreStdlibSupport
        default:
            return coreStdlibSupport
        }
    }

    /// Of `modules`, the ones that are not yet importable (with their reasons).
    /// A backend can call this before a build to fail fast with a clear message
    /// instead of a confusing toolchain crash.
    public func blockedImports(among modules: [String]) -> [(module: String, support: ModuleSupport)] {
        modules.compactMap { m in
            let s = support(forImporting: m)
            return s.isSupported ? nil : (m, s)
        }
    }

    // MARK: Triple

    /// The Swift target triple for `target`, or nil for `.host` (which this
    /// cross-compile driver does not target).
    public func triple(for target: TargetPlatform) -> String? {
        switch target {
        case .host: return nil
        case .iosArm64: return "arm64-apple-ios\(iosDeploymentTarget)"
        case .iosSimulator: return "arm64-apple-ios\(iosDeploymentTarget)-simulator"
        }
    }

    // MARK: Argument vector (exposed for preview + tests)

    /// Build the `swift-frontend` argv to compile `source` to `object`.
    ///
    /// - `sdkPath == nil` → SDK-free path: `-parse-stdlib -disable-objc-interop`.
    /// - `sdkPath != nil` → core-stdlib path: `-sdk <sdk>`, plus
    ///   `-resource-dir` / `-module-cache-path` when configured.
    public func compileArguments(source: String, object: String,
                                 target: TargetPlatform, sdkPath: String?,
                                 extraArguments: [String]) -> [String] {
        var args = ["-frontend", "-emit-object"]
        if let triple = triple(for: target) {
            args += ["-target", triple]
        }
        if let sdkPath {
            args += ["-sdk", sdkPath]
            if let resourceDir { args += ["-resource-dir", resourceDir] }
            if let moduleCachePath { args += ["-module-cache-path", moduleCachePath] }
        } else {
            args += ["-parse-stdlib", "-disable-objc-interop"]
        }
        args += extraArguments
        args += ["-o", object, source]
        return args
    }

    // MARK: ToolchainDriver

    public func compile(source: String, to object: String, target: TargetPlatform,
                        sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic] {
        guard triple(for: target) != nil else {
            throw ToolchainError.unsupportedTarget(target)
        }
        let args = compileArguments(source: source, object: object, target: target,
                                    sdkPath: sdkPath, extraArguments: extraArguments)
        let result = try runner.run(arguments: args)
        var diags = WasmFrontendDriver.parseDiagnostics(result.standardError)
        if result.exitCode != 0 {
            if !diags.contains(where: { $0.isError }) {
                let summary = WasmFrontendDriver.firstNonEmptyLine(result.standardError)
                    ?? "swift-frontend exited with code \(result.exitCode)"
                diags.append(ToolchainDiagnostic(severity: .error, message: summary, file: source))
            }
            throw ToolchainError.compileFailed(source: source, diagnostics: diags)
        }
        return diags
    }

    public func link(objects: [String], to image: String, target: TargetPlatform,
                     sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic] {
        // The wasm frontend emits objects only. Linking an image (dylib / app)
        // is a distinct `ld64.lld` + `ldid` step (the LiveProcess / on-device
        // path). Surface that clearly rather than silently "succeeding".
        let diag = ToolchainDiagnostic(
            severity: .error,
            message: "wasm-xc emits objects only; linking \(image) requires a "
                + "separate ld64.lld + ldid step (not wired here)",
            file: image
        )
        throw ToolchainError.linkFailed(image: image, diagnostics: [diag])
    }

    // MARK: Diagnostic parsing

    /// Parse `swift-frontend` stderr into structured diagnostics. Recognizes the
    /// standard `path:line:col: severity: message` form and bare
    /// `severity: message` lines.
    static func parseDiagnostics(_ stderr: String) -> [ToolchainDiagnostic] {
        var out: [ToolchainDiagnostic] = []
        // `file:line:col: severity: message`
        let located = try? NSRegularExpression(
            pattern: #"^(.*?):(\d+):(\d+):\s*(error|warning|note):\s*(.*)$"#)
        // bare `severity: message`
        let bare = try? NSRegularExpression(
            pattern: #"^\s*(error|warning|note):\s*(.*)$"#)

        for raw in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)

            if let m = located?.firstMatch(in: line, range: range),
               let fileR = Range(m.range(at: 1), in: line),
               let lineR = Range(m.range(at: 2), in: line),
               let sevR = Range(m.range(at: 4), in: line),
               let msgR = Range(m.range(at: 5), in: line),
               let severity = ToolchainDiagnostic.Severity(rawValue: String(line[sevR])) {
                out.append(ToolchainDiagnostic(
                    severity: severity,
                    message: String(line[msgR]).trimmingCharacters(in: .whitespaces),
                    file: String(line[fileR]),
                    line: Int(line[lineR])
                ))
                continue
            }

            if let m = bare?.firstMatch(in: line, range: range),
               let sevR = Range(m.range(at: 1), in: line),
               let msgR = Range(m.range(at: 2), in: line),
               let severity = ToolchainDiagnostic.Severity(rawValue: String(line[sevR])) {
                out.append(ToolchainDiagnostic(
                    severity: severity,
                    message: String(line[msgR]).trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return out
    }

    static func firstNonEmptyLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
