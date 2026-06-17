import Foundation

/// A compile/link toolchain that produces native code, abstracted so the
/// cross-platform engine can drive it without depending on any concrete
/// compiler.
///
/// This is the seam for **on-device** iOS compilation. swiftbox cannot
/// `fork`/`exec` a real `swiftc`/`clang` on iOS, but the emexDE / Nyxian
/// **CoreCompiler** exposes an in-process CoreFoundation API
/// (`CCSDKCreateWithDirectoryURL` → `CCDriverCreate(args, type)` →
/// `CCDriverCreateJobs` → `CCJobExecuteJob`) plus a linker. The Apple app target
/// implements ``ToolchainDriver`` over that API; here in the cross-platform core
/// the protocol is exercised with ``StubToolchainDriver`` so the
/// compiled-recipe build path is real and tested on the desktop.
///
/// The same shape also fits the Mac-free wasm cross-compiler (once its
/// ClangImporter crash is fixed) — that driver would shell out to
/// `ios/crosscompile.sh`. Either backend plugs in behind this one protocol.
public protocol ToolchainDriver: AnyObject {
    /// A human label for diagnostics (e.g. "corecompiler", "wasm-xc").
    var name: String { get }

    /// Compile one source file to a native object. `source`/`object` are paths
    /// in the build environment (the VFS path on device, a host path off it).
    /// Returns the diagnostics produced; throws on a hard failure.
    func compile(source: String, to object: String, target: TargetPlatform, sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic]

    /// Link object files into a final image (dylib/executable). Returns
    /// diagnostics; throws on a hard failure.
    func link(objects: [String], to image: String, target: TargetPlatform, sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic]
}

/// A diagnostic emitted by a ``ToolchainDriver`` (mirrors `CCDiagnostic`).
public struct ToolchainDiagnostic: Equatable {
    public enum Severity: String, Equatable { case note, warning, error }
    public var severity: Severity
    public var message: String
    public var file: String?
    public var line: Int?

    public init(severity: Severity, message: String, file: String? = nil, line: Int? = nil) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
    }

    public var isError: Bool { severity == .error }
}

public enum ToolchainError: Error, Equatable {
    case compileFailed(source: String, diagnostics: [ToolchainDiagnostic])
    case linkFailed(image: String, diagnostics: [ToolchainDiagnostic])
    case noSDK
    case unsupportedTarget(TargetPlatform)
}

/// A no-op driver that "compiles" by writing a placeholder object and "links"
/// by concatenating object names — for exercising the build-pipeline wiring on
/// the desktop without a real compiler. Records every call for assertions.
public final class StubToolchainDriver: ToolchainDriver {
    public let name = "stub"
    private let vfs: VirtualFileSystem
    public private(set) var compiled: [(source: String, object: String)] = []
    public private(set) var linked: [(objects: [String], image: String)] = []

    /// When set, `compile` fails for sources whose path contains this marker,
    /// to test the error path.
    public var failSourcesContaining: String?

    public init(vfs: VirtualFileSystem) {
        self.vfs = vfs
    }

    public func compile(source: String, to object: String, target: TargetPlatform, sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic] {
        if let marker = failSourcesContaining, source.contains(marker) {
            let diag = ToolchainDiagnostic(severity: .error, message: "stub: forced failure", file: source)
            throw ToolchainError.compileFailed(source: source, diagnostics: [diag])
        }
        try vfs.writeFile(object, string: "OBJ(\(source))\n")
        compiled.append((source, object))
        return []
    }

    public func link(objects: [String], to image: String, target: TargetPlatform, sdkPath: String?, extraArguments: [String]) throws -> [ToolchainDiagnostic] {
        let body = objects.map { (try? vfs.readString($0)) ?? "" }.joined()
        try vfs.writeFile(image, string: "IMAGE[\(target.rawValue)]\n" + body)
        linked.append((objects, image))
        return []
    }
}
