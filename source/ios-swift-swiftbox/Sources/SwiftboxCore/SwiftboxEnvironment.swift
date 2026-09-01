import Foundation

/// Top-level façade that wires the filesystem, package repository, shell and
/// kernel together and lays down the initial `$PREFIX` userland — the swiftbox
/// equivalent of Termux's bootstrap.
public final class SwiftboxEnvironment {
    public static let version = "0.38.0"

    /// Userland install prefix. On device this is mirrored onto the app's
    /// sandbox container; here it is purely virtual.
    public static let prefix = "/data/swiftbox/usr"
    public static let home = "/data/swiftbox/home"

    /// Virtual root that persistence mirrors (covers both `usr` and `home`).
    public static let persistRoot = "/data/swiftbox"

    public let vfs: VirtualFileSystem
    public let repository: PackageRepository
    public let shell: Shell
    public let kernel: Kernel
    public let catalog: PackageCatalog
    public let builder: PackageBuilder

    /// Host directory the virtual `$PREFIX` is mirrored to/from, if any. On iOS
    /// this becomes a path inside the app's sandbox container.
    public let containerPath: String?

    /// On-disk package store under the container, when one is configured. Built
    /// packages are published here and `pkg update`/`pkg upgrade` operate on it.
    public let store: LocalPackageStore?

    /// Create an environment. When `container` is given, any previously-saved
    /// state there is loaded over the fresh bootstrap, and ``persist()`` writes
    /// the current tree back. `runProfile` controls whether `.profile` is
    /// sourced on launch (default true). `allowNetwork` enables an HTTPS source
    /// fallback for `pkg fetch` (default false — offline-first).
    public init(container: String? = nil, runProfile: Bool = true, allowNetwork: Bool = false) {
        self.containerPath = container
        vfs = VirtualFileSystem()
        repository = PackageRepository()
        catalog = CatalogSeed.makeDefaultCatalog()

        // When a container is configured, packages persist to an on-disk store.
        let store: LocalPackageStore?
        if let container {
            store = LocalPackageStore(root: (container as NSString).appendingPathComponent("packages"))
        } else {
            store = nil
        }
        self.store = store

        var env: [String: String] = [:]
        env["PREFIX"] = SwiftboxEnvironment.prefix
        env["HOME"] = SwiftboxEnvironment.home
        env["PATH"] = "\(SwiftboxEnvironment.prefix)/bin"
        env["TMPDIR"] = "\(SwiftboxEnvironment.prefix)/tmp"
        env["TERM"] = "xterm-256color"
        env["SHELL"] = "\(SwiftboxEnvironment.prefix)/bin/sh"
        env["SWIFTBOX_VERSION"] = SwiftboxEnvironment.version

        shell = Shell(
            vfs: vfs,
            repository: repository,
            environment: env,
            cwd: SwiftboxEnvironment.home
        )
        kernel = SimulatedKernel(shell: shell)
        builder = PackageBuilder(
            catalog: catalog,
            repository: repository,
            backend: HostBuildBackend(),
            vfs: vfs,
            prefix: SwiftboxEnvironment.prefix,
            store: store
        )

        bootstrap()
        shell.catalog = catalog
        shell.builder = builder
        shell.packageStore = store

        // Source acquisition: local provider (+ optional network fallback) and
        // an on-disk cache under the container, so fetch → verify → cache works
        // fully offline by default, with HTTPS available when explicitly enabled.
        if let container {
            let cache = SourceCache(root: (container as NSString).appendingPathComponent("sources"))
            let provider: SourceProvider = allowNetwork
                ? ChainSourceProvider([FileSourceProvider(), HTTPSourceProvider()])
                : FileSourceProvider()
            shell.sourceFetcher = SourceFetcher(provider: provider, cache: cache)
        }

        // Remote signed-index distribution: enabled only when networking is on,
        // so `pkg update <url>` can pull and verify a hosted index.
        if allowNetwork {
            shell.remoteIndexClient = RemoteIndexClient(signingKey: shell.indexSigningKey)
        }

        // Rehydrate any previously-persisted state from the sandbox container.
        if let container {
            _ = try? VFSPersistence.load(vfs, root: SwiftboxEnvironment.persistRoot, from: container)
            restoreInstalledRegistry()
        }

        if runProfile { _ = self.runProfile() }
    }

    /// Where the installed-package registry is recorded inside the VFS. It lives
    /// under `persistRoot`, so it travels with the container automatically —
    /// making a persisted sandbox truly portable (its `pkg list-installed` state
    /// survives a move/copy, not just its files).
    public static var installedRegistryPath: String {
        "\(prefix)/var/lib/swiftbox/installed.list"
    }

    /// Re-mark packages installed from the persisted registry, ignoring names no
    /// longer in the catalog.
    private func restoreInstalledRegistry() {
        guard let text = try? vfs.readString(SwiftboxEnvironment.installedRegistryPath) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, repository.manifest(for: name) != nil {
                repository.markInstalled(name)
            }
        }
    }

    /// Write the current installed set into the VFS so the next ``persist()``
    /// carries it to disk.
    private func saveInstalledRegistry() {
        _ = try? vfs.makeDirectory("\(SwiftboxEnvironment.prefix)/var/lib/swiftbox")
        let list = repository.installed.sorted().joined(separator: "\n")
        try? vfs.writeFile(
            SwiftboxEnvironment.installedRegistryPath,
            string: list.isEmpty ? "" : list + "\n"
        )
    }

    /// Source `$HOME/.profile` in the shell, as a login shell would on start.
    @discardableResult
    public func runProfile() -> CommandResult {
        let profile = "\(SwiftboxEnvironment.home)/.profile"
        guard let text = try? vfs.readString(profile) else { return .success }
        return shell.runSource(text)
    }

    /// Create an interactive ``Session`` bound to this environment's shell.
    public func makeSession(rows: Int = 24, columns: Int = 80) -> Session {
        Session(shell: shell, rows: rows, columns: columns)
    }

    /// Persist the current virtual `$PREFIX`/home tree to the sandbox container.
    /// No-op when no container was configured. Returns the number of files written.
    @discardableResult
    public func persist() throws -> Int {
        guard let containerPath else { return 0 }
        saveInstalledRegistry()
        return try VFSPersistence.save(vfs, root: SwiftboxEnvironment.persistRoot, to: containerPath)
    }

    /// A summary of a scaffolded portable sandbox.
    public struct ScaffoldReport: Equatable {
        public let container: String
        public let filesWritten: Int
        public let installed: [String]
    }

    /// Scaffold a fresh, **portable** sandbox at `container`: bootstrap the base
    /// filesystem, write a starter `README` + `.profile` into `$HOME`, optionally
    /// install the given packages, and persist it all to disk. The resulting
    /// directory is self-contained — point any later `SwiftboxEnvironment(
    /// container:)` (or `swiftbox --container`) at it and the files **and**
    /// installed-package state come back. Returns a summary.
    @discardableResult
    public static func scaffold(at container: String, install: [String] = []) throws -> ScaffoldReport {
        let env = SwiftboxEnvironment(container: container, runProfile: false)
        try? env.vfs.writeFile(
            "\(home)/README",
            string: """
            Welcome to your portable swiftbox sandbox.

            This directory is a self-contained sandbox container: its filesystem
            and installed packages persist here. Open it with:

                swiftbox --container <this directory>

            Type 'help' for builtins, 'pkg catalog' to browse packages.
            """
        )
        try? env.vfs.writeFile(
            "\(home)/.profile",
            string: "# swiftbox login profile\nexport PS1='$ '\nexport EDITOR=ed\n"
        )
        for pkg in install {
            _ = env.shell.run("pkg install \(pkg)")
        }
        let written = try env.persist()
        return ScaffoldReport(
            container: container,
            filesWritten: written,
            installed: env.repository.installed.sorted()
        )
    }

    private func bootstrap() {
        let dirs = [
            "\(SwiftboxEnvironment.prefix)/bin",
            "\(SwiftboxEnvironment.prefix)/lib",
            "\(SwiftboxEnvironment.prefix)/etc",
            "\(SwiftboxEnvironment.prefix)/etc/profile.d",
            "\(SwiftboxEnvironment.prefix)/tmp",
            "\(SwiftboxEnvironment.prefix)/var/lib/swiftbox",
            SwiftboxEnvironment.home,
        ]
        for d in dirs { _ = try? vfs.makeDirectory(d) }
        try? vfs.writeFile(
            "\(SwiftboxEnvironment.home)/.profile",
            string: "# swiftbox profile\nexport PS1='$ '\n"
        )
        seedCoreRepository()
        // Publish every catalog manifest so the resolver can plan installs and
        // builds across the whole catalog, not just the bootstrap core set.
        for recipe in catalog.recipes.values {
            repository.publish(recipe.manifest)
        }
    }

    /// The minimal package set shipped with the bootstrap. These are the iOS
    /// rebuilds of the utilities Termux ships for Android.
    private func seedCoreRepository() {
        let core: [PackageManifest] = [
            PackageManifest(
                name: "libc-shim",
                version: SemanticVersion(0, 1, 0),
                summary: "iOS sandbox libc / syscall shim layer"
            ),
            PackageManifest(
                name: "swiftbox-core",
                version: SemanticVersion(0, 1, 0),
                summary: "swiftbox core userland and shell",
                dependencies: ["libc-shim"]
            ),
            PackageManifest(
                name: "coreutils",
                version: SemanticVersion(0, 1, 0),
                summary: "Basic file, shell and text utilities",
                dependencies: ["libc-shim"]
            ),
            PackageManifest(
                name: "swift-toolchain",
                version: SemanticVersion(6, 3, 1),
                summary: "On-device Swift toolchain (LiveProcess backend)",
                dependencies: ["libc-shim", "coreutils"]
            ),
        ]
        for manifest in core { repository.publish(manifest) }
    }
}
