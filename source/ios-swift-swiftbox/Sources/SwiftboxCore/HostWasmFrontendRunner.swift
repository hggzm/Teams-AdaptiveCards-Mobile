import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A ``WasmFrontendRunner`` that executes the real wasm-hosted `swift-frontend`
/// by spawning `wasmtime` on the host via `Foundation.Process`.
///
/// This is the bridge that lets swiftbox's *own* Swift code drive the validated
/// Mac-free cross-compiler (no shell script): it runs
/// `wasmtime run --allow-precompiled --dir / <cwasm> -frontend …` and captures
/// stdout/stderr/exit. It is pure cross-platform Swift (Foundation only), so it
/// builds on macOS / Linux / Windows; the actual run obviously needs `wasmtime`
/// and the AOT `.cwasm` present, which is why the `swift test` gate exercises
/// the *argv construction* hermetically and real execution happens off-band
/// (`ios/smoke-xc.sh`).
public final class HostWasmFrontendRunner: WasmFrontendRunner {
    public enum RunnerError: Error, Equatable {
        case wasmtimeNotFound(String)
        case frontendNotFound(String)
        case spawnFailed(String)
    }

    /// A single host→guest directory exposure for the WASI sandbox
    /// (`--dir <host>::<guest>`).
    public struct HostMount: Equatable {
        public let host: String
        public let guest: String
        public init(host: String, guest: String) {
            self.host = host
            self.guest = guest
        }
    }

    /// How the host filesystem is exposed to the wasm (WASI) sandbox.
    ///
    /// On Linux/WSL the host paths *are* valid guest paths, so `--dir /` and
    /// pass-through work. On **Windows**, host paths (`C:\…`) are not valid WASI
    /// paths and the frontend can't `chdir` to a non-preopened `/`, so each host
    /// directory must be **mapped** (`--dir <host>::<guest>`) and the path
    /// arguments under it rewritten to guest-absolute form. This is what makes a
    /// single-host build work on Windows (no WSL hop). A core-stdlib build needs
    /// two mounts: the work dir onto guest `/`, and the iOS SDK onto e.g. `/sdk`.
    public enum Mount: Equatable {
        /// `--dir /`, host paths used verbatim as guest paths (Linux/WSL).
        case rootPassthrough
        /// Each `(host, guest)` is exposed via `--dir host::guest`; any path
        /// argument under a `host` dir is rewritten to a `guest`-rooted path
        /// (Windows). By convention the work dir maps to guest `/`.
        case mappedDirs([HostMount])

        /// Convenience: a single host dir mapped onto guest `/`.
        public static func mapHostDirToRoot(_ dir: String) -> Mount {
            .mappedDirs([HostMount(host: dir, guest: "/")])
        }
    }

    /// Path to the `wasmtime` executable.
    public let wasmtimePath: String
    /// Path to the AOT-compiled frontend (`sf_xc.cwasm`).
    public let frontendPath: String
    /// How the host FS is exposed to the sandbox.
    public let mount: Mount

    public init(wasmtimePath: String, frontendPath: String, mount: Mount = .rootPassthrough) {
        self.wasmtimePath = wasmtimePath
        self.frontendPath = frontendPath
        self.mount = mount
    }

    /// Back-compat convenience: a plain `--dir <mountDir>` pass-through mount.
    public convenience init(wasmtimePath: String, frontendPath: String, mountDir: String) {
        self.init(wasmtimePath: wasmtimePath, frontendPath: frontendPath,
                  mount: mountDir == "/" ? .rootPassthrough : .mapHostDirToRoot(mountDir))
    }

    /// Rewrite a single frontend argument to its guest form under the current
    /// mount. Pass-through leaves it unchanged; mapped mounts rewrite any path
    /// under a mapped `host` dir to its `guest`-rooted form (normalizing `\` →
    /// `/`). The longest matching host prefix wins, so nested mounts resolve
    /// correctly. Non-path args (and paths outside every mount) are unchanged.
    func guestArgument(_ arg: String) -> String {
        switch mount {
        case .rootPassthrough:
            return arg
        case .mappedDirs(let mounts):
            let normArg = arg.replacingOccurrences(of: "\\", with: "/")
            for m in mounts.sorted(by: { $0.host.count > $1.host.count }) {
                let normHost = m.host.replacingOccurrences(of: "\\", with: "/")
                guard normArg.hasPrefix(normHost) else { continue }
                var rel = String(normArg.dropFirst(normHost.count))
                while rel.hasPrefix("/") { rel.removeFirst() }
                let guestBase = (m.guest == "/") ? "" :
                    (m.guest.hasSuffix("/") ? String(m.guest.dropLast()) : m.guest)
                // When the arg is exactly the mount root, emit the guest root
                // itself (no trailing slash); otherwise join with "/".
                if rel.isEmpty { return guestBase.isEmpty ? "/" : guestBase }
                return guestBase + "/" + rel
            }
            return arg
        }
    }

    /// The full `wasmtime` argv for a given frontend argument vector. Exposed for
    /// hermetic testing (no process spawned).
    public func wasmtimeArguments(frontendArguments: [String]) -> [String] {
        var args = ["run", "--allow-precompiled"]
        switch mount {
        case .rootPassthrough:
            args += ["--dir", "/"]
        case .mappedDirs(let mounts):
            for m in mounts { args += ["--dir", "\(m.host)::\(m.guest)"] }
        }
        args.append(frontendPath)
        return args + frontendArguments.map(guestArgument)
    }

    public func run(arguments: [String]) throws -> WasmFrontendResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: wasmtimePath) || fm.fileExists(atPath: wasmtimePath) else {
            throw RunnerError.wasmtimeNotFound(wasmtimePath)
        }
        guard fm.fileExists(atPath: frontendPath) else {
            throw RunnerError.frontendNotFound(frontendPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wasmtimePath)
        process.arguments = wasmtimeArguments(frontendArguments: arguments)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw RunnerError.spawnFailed("\(error)")
        }

        // Read both pipes to EOF *before* waiting, so a child that fills a pipe
        // buffer can't deadlock against our wait. The frontend has no
        // grandchildren, so readDataToEndOfFile is safe here.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return WasmFrontendResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}
