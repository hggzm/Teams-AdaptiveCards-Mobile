import Foundation

/// The result of running an external host command.
public struct CommandOutput: Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs an external executable with arguments. Injected so the *argv contract*
/// of the link/sign drivers is unit-tested headlessly while real execution
/// happens off-band (the actual `ld64.lld`/`ldid` need a Mach-O-capable build).
public protocol CommandRunner: AnyObject {
    func run(executable: String, arguments: [String]) throws -> CommandOutput
}

/// A ``CommandRunner`` over `Foundation.Process`. Pure cross-platform Swift.
public final class HostCommandRunner: CommandRunner {
    public enum RunnerError: Error, Equatable {
        case executableNotFound(String)
        case spawnFailed(String)
    }

    public init() {}

    public func run(executable: String, arguments: [String]) throws -> CommandOutput {
        guard FileManager.default.fileExists(atPath: executable) else {
            throw RunnerError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { throw RunnerError.spawnFailed("\(error)") }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }
}

/// Errors surfaced by the Mach-O image tools.
public enum MachOToolError: Error, Equatable {
    case linkFailed(image: String, diagnostics: [ToolchainDiagnostic])
    case signFailed(image: String, message: String)
    case unsupported(reason: String, tracking: String)
}

/// Links Mach-O object files into a dylib or executable image via `ld64.lld`.
///
/// The wasm frontend emits objects only; producing a *loadable image* is a
/// separate link step. This driver builds the `ld64.lld` argv and runs it via a
/// ``CommandRunner``.
///
/// **Capability captured as data.** On this DevBox the Windows Swift toolchain's
/// `ld64.lld` (LLD 21) is built **without Mach-O platform support** — it rejects
/// every Apple platform (`error: This version of lld does not support linking
/// for platform macOS/iOS`). So `machOSupported` is `.blocked` by default; a host
/// with a Mach-O-capable `ld64.lld` flips it to `.supported`. Note: desktop
/// linking is **not required** for the on-device path — emexDE / LiveProcess
/// links and loads on the device; swiftbox's cross-compile deliverable is the
/// object file.
public final class MachOLinker {
    public enum ImageKind: Equatable { case dylib, executable }

    public let linkerPath: String
    private let runner: CommandRunner

    /// iOS deployment + SDK versions for the `-platform_version` 3-tuple.
    public var iosDeploymentTarget: String
    public var sdkVersion: String

    /// Whether this linker can actually produce Apple Mach-O images. Default
    /// `.blocked` (the Windows toolchain lld can't); set `.supported` on a host
    /// with a Mach-O-capable `ld64.lld`.
    public var machOSupported: ModuleSupport = .blocked(
        reason: "the bundled ld64.lld (Windows Swift toolchain, LLD 21) is built "
            + "without Mach-O platform support and rejects all Apple platforms; "
            + "use a Mach-O-capable ld64.lld, or link on-device via emexDE",
        tracking: "swiftbox/ios-link"
    )

    public init(linkerPath: String, runner: CommandRunner,
                iosDeploymentTarget: String = "16.5", sdkVersion: String = "16.5") {
        self.linkerPath = linkerPath
        self.runner = runner
        self.iosDeploymentTarget = iosDeploymentTarget
        self.sdkVersion = sdkVersion
    }

    /// The `ld64.lld` platform name for a target.
    func platformName(for target: TargetPlatform) -> String {
        switch target {
        case .iosArm64: return "ios"
        case .iosSimulator: return "ios-simulator"
        case .host: return "macos"
        }
    }

    /// Build the `ld64.lld` argv for a link. `sdkPath` supplies `-syslibroot`
    /// (so system stubs resolve) and `-lSystem`.
    public func linkArguments(objects: [String], to image: String,
                              target: TargetPlatform, sdkPath: String?,
                              kind: ImageKind, extraArguments: [String]) -> [String] {
        var args = ["-arch", "arm64",
                    "-platform_version", platformName(for: target),
                    iosDeploymentTarget, sdkVersion]
        args += (kind == .dylib) ? ["-dylib"] : ["-execute"]
        args += ["-o", image]
        args += objects
        if let sdkPath {
            args += ["-syslibroot", sdkPath, "-lSystem"]
        }
        args += extraArguments
        return args
    }

    public func link(objects: [String], to image: String, target: TargetPlatform,
                     sdkPath: String?, kind: ImageKind = .dylib,
                     extraArguments: [String] = []) throws -> [ToolchainDiagnostic] {
        if case .blocked(let reason, let tracking) = machOSupported {
            throw MachOToolError.unsupported(reason: reason, tracking: tracking)
        }
        let args = linkArguments(objects: objects, to: image, target: target,
                                 sdkPath: sdkPath, kind: kind, extraArguments: extraArguments)
        let result = try runner.run(executable: linkerPath, arguments: args)
        let diags = WasmFrontendDriver.parseDiagnostics(result.standardError)
        if result.exitCode != 0 {
            var all = diags
            if !all.contains(where: { $0.isError }) {
                let line = WasmFrontendDriver.firstNonEmptyLine(result.standardError)
                    ?? "ld64.lld exited with code \(result.exitCode)"
                all.append(ToolchainDiagnostic(severity: .error, message: line, file: image))
            }
            throw MachOToolError.linkFailed(image: image, diagnostics: all)
        }
        return diags
    }
}

/// Ad-hoc / entitlement signs a Mach-O image with `ldid` (the open-source signer
/// used by the jailbreak / on-device toolchains). `ldid -S` ad-hoc signs;
/// `ldid -S<entitlements.plist>` embeds entitlements.
public final class MachOSigner {
    public let ldidPath: String
    private let runner: CommandRunner

    public init(ldidPath: String, runner: CommandRunner) {
        self.ldidPath = ldidPath
        self.runner = runner
    }

    /// Build the `ldid` argv: `-S` (ad-hoc) or `-S<entitlements>` then the image.
    public func signArguments(image: String, entitlementsPath: String?) -> [String] {
        let flag = entitlementsPath.map { "-S" + $0 } ?? "-S"
        return [flag, image]
    }

    public func sign(image: String, entitlementsPath: String? = nil) throws {
        let result = try runner.run(
            executable: ldidPath,
            arguments: signArguments(image: image, entitlementsPath: entitlementsPath))
        if result.exitCode != 0 {
            let msg = WasmFrontendDriver.firstNonEmptyLine(result.standardError)
                ?? "ldid exited with code \(result.exitCode)"
            throw MachOToolError.signFailed(image: image, message: msg)
        }
    }
}
