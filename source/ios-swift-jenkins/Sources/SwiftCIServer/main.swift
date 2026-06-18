import Foundation
import SwiftCIKit
import Vapor

/// `swiftci serve` entry point.
///
/// Configuration via environment variables (Vapor's standard mechanism):
///   - `SWIFTCI_DATA_DIR` — where jobs are persisted. Defaults to
///     `%ProgramData%\swiftci` on Windows, `/var/lib/swiftci` on Linux,
///     `~/Library/Application Support/swiftci` on macOS.
///   - All standard Vapor env vars (port, hostname, log level, etc.).
@main
struct Entry {
    static func main() async throws {
        // Side-channel subcommands handled before Vapor's
        // Environment.detect() so they don't need a configured app.
        let argv = CommandLine.arguments
        if argv.count >= 2, argv[1] == "import" {
            try runImport(arguments: Array(argv.dropFirst(2)))
            return
        }
        if argv.count >= 2, argv[1] == "--help" || argv[1] == "-h" {
            printUsage()
            return
        }

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)

        let dataDir = Self.resolveDataDir()
        app.logger.notice("swiftci data dir: \(dataDir)")
        let store = JobStore(rootPath: dataDir)
        // Phase 37: credential store is wired up always. On-disk file
        // (`credentials.json`) is created lazily on first POST.
        let credentialStore = CredentialStore(jobStore: store)
        // Production deployment uses URLSession for outbound webhook
        // notifications. Tests construct `BuildExecutor` directly with
        // `NoopBuildNotifier()` (the default) to avoid touching
        // `URLSession.shared` at all, which has slow cold-start
        // behaviour on Windows that can stall the executor actor.
        let executor = BuildExecutor(
            store: store,
            notifier: URLSessionBuildNotifier(),
            credentialStore: credentialStore
        )
        await executor.start()
        let publicDir = Self.resolvePublicDir()
        if FileManager.default.fileExists(atPath: publicDir) {
            app.logger.notice("swiftci public dir: \(publicDir)")
        } else {
            app.logger.notice("swiftci public dir not found at \(publicDir); UI disabled")
        }
        let webhookToken = ProcessInfo.processInfo.environment["SWIFTCI_WEBHOOK_TOKEN"]
        if webhookToken != nil {
            app.logger.notice("swiftci webhook token: configured")
        } else {
            app.logger.notice("swiftci webhook token: NOT set (POST /webhook/:id is unauthenticated)")
        }
        let adminToken = ProcessInfo.processInfo.environment["SWIFTCI_ADMIN_TOKEN"]
        if adminToken != nil {
            app.logger.notice("swiftci admin token: configured (mutation routes require Bearer)")
        } else {
            app.logger.notice("swiftci admin token: NOT set (POST /api/jobs, /trigger, /cancel are unauthenticated)")
        }
        // Phase 35: persistent scope-based API tokens. Always wired up;
        // the on-disk file (`tokens.json`) is lazily created when the
        // first token is minted via `POST /api/tokens`. The legacy
        // `SWIFTCI_ADMIN_TOKEN` still authorizes all mutation routes
        // unchanged, so existing deployments continue working without
        // any token-store entries.
        let tokenStore = APITokenStore(jobStore: store)
        app.logger.notice("swiftci api tokens: enabled (POST /api/tokens to mint)")
        app.logger.notice("swiftci credentials: enabled (POST /api/credentials to register)")
        SwiftCIApp.configure(app, store: store, executor: executor,
                             publicDirectory: publicDir,
                             webhookToken: webhookToken,
                             adminToken: adminToken,
                             tokenStore: tokenStore,
                             credentialStore: credentialStore)

        defer {
            Task {
                await executor.stop()
                try? await app.asyncShutdown()
            }
        }

        try await app.execute()
    }

    static func resolveDataDir() -> String {
        if let override = ProcessInfo.processInfo.environment["SWIFTCI_DATA_DIR"] {
            return override
        }
        #if os(Windows)
        let pd = ProcessInfo.processInfo.environment["ProgramData"] ?? "C:\\ProgramData"
        return "\(pd)\\swiftci"
        #elseif os(macOS)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/Library/Application Support/swiftci"
        #else
        return "/var/lib/swiftci"
        #endif
    }

    /// Resolve the static-asset directory.
    ///
    /// Honors `SWIFTCI_PUBLIC_DIR` if set. Otherwise looks for `Public/`
    /// in the process's current working directory — Vapor's
    /// `app.directory.publicDirectory` default behavior.
    static func resolvePublicDir() -> String {
        if let override = ProcessInfo.processInfo.environment["SWIFTCI_PUBLIC_DIR"] {
            return override
        }
        let cwd = FileManager.default.currentDirectoryPath
        #if os(Windows)
        return "\(cwd)\\Public"
        #else
        return "\(cwd)/Public"
        #endif
    }

    /// `swiftci import jenkinsfile <path> [--name <pipeline name>] [-o <out.yaml>]`
    ///
    /// Reads a declarative Jenkinsfile, parses it via
    /// `JenkinsfileImporter`, and writes the resulting swiftci YAML
    /// to stdout (or `-o <path>`). Warnings go to stderr. Exit code
    /// 0 even if there are warnings — exit 1 only on parse error.
    static func runImport(arguments: [String]) throws {
        guard let kind = arguments.first, kind == "jenkinsfile" else {
            fputs("usage: swiftci import jenkinsfile <path> [--name N] [-o out.yaml]\n", stderr)
            exit(2)
        }
        var rest = Array(arguments.dropFirst())
        var path: String? = nil
        var name: String = "Imported"
        var outPath: String? = nil
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--name":
                guard !rest.isEmpty else {
                    fputs("error: --name requires a value\n", stderr); exit(2)
                }
                name = rest.removeFirst()
            case "-o", "--output":
                guard !rest.isEmpty else {
                    fputs("error: -o requires a value\n", stderr); exit(2)
                }
                outPath = rest.removeFirst()
            case "-h", "--help":
                fputs("usage: swiftci import jenkinsfile <path> [--name N] [-o out.yaml]\n", stderr)
                exit(0)
            default:
                if path == nil { path = a }
                else {
                    fputs("error: unexpected argument `\(a)`\n", stderr); exit(2)
                }
            }
        }
        guard let p = path else {
            fputs("error: missing <path>\n", stderr); exit(2)
        }
        let source: String
        do {
            source = try String(contentsOfFile: p, encoding: .utf8)
        } catch {
            fputs("error: could not read `\(p)`: \(error)\n", stderr); exit(1)
        }
        // If the user didn't supply --name, use the file's basename.
        if name == "Imported" {
            let base = (p as NSString).lastPathComponent
            if base.lowercased() == "jenkinsfile" {
                // Use the parent directory's last component as the name.
                let parent = (p as NSString).deletingLastPathComponent
                let parentBase = (parent as NSString).lastPathComponent
                if !parentBase.isEmpty { name = parentBase }
            } else if !base.isEmpty {
                name = (base as NSString).deletingPathExtension
            }
        }

        let result: JenkinsfileImporter.Result
        do {
            result = try JenkinsfileImporter.parse(source, defaultName: name)
        } catch {
            fputs("error: \(error)\n", stderr); exit(1)
        }

        for w in result.warnings {
            fputs("warning: \(w)\n", stderr)
        }
        let yaml: String
        do {
            yaml = try result.pipeline.encodeYAML()
        } catch {
            fputs("error: could not encode YAML: \(error)\n", stderr); exit(1)
        }
        if let outPath {
            do {
                try yaml.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                fputs("error: could not write `\(outPath)`: \(error)\n", stderr); exit(1)
            }
            fputs("wrote \(outPath) (\(result.pipeline.steps.count) step\(result.pipeline.steps.count == 1 ? "" : "s"), \(result.warnings.count) warning\(result.warnings.count == 1 ? "" : "s"))\n", stderr)
        } else {
            print(yaml)
        }
        exit(0)
    }

    static func printUsage() {
        let usage = """
        swiftci — Swift-native CI server

        Commands:
          swiftci serve                     Start the HTTP server.
          swiftci import jenkinsfile <path> Convert a declarative Jenkinsfile
                                            to swiftci pipeline YAML.

        See README.md for environment variables and the full route list.
        """
        print(usage)
    }
}
