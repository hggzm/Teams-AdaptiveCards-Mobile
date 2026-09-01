import Foundation

/// Drives a build: resolve dependency order from the catalog, build each
/// package with the chosen backend, stage artifacts into the filesystem, and
/// mark successfully-built packages installed in the repository.
public final class PackageBuilder {
    public let catalog: PackageCatalog
    public let repository: PackageRepository
    public let backend: BuildBackend
    private let vfs: VirtualFileSystem
    private let prefix: String

    /// Optional on-disk store. When set, every successfully-built package is
    /// also published as a `.sbox` archive so it can be installed later without
    /// rebuilding.
    public var store: LocalPackageStore?

    public init(
        catalog: PackageCatalog,
        repository: PackageRepository,
        backend: BuildBackend,
        vfs: VirtualFileSystem,
        prefix: String,
        store: LocalPackageStore? = nil
    ) {
        self.catalog = catalog
        self.repository = repository
        self.backend = backend
        self.vfs = vfs
        self.prefix = prefix
        self.store = store
    }

    public enum BuildError: Error, Equatable {
        case notInCatalog(String)
        case dependencyCycle([String])
    }

    /// Build `roots` and their dependencies (dependencies first). Returns one
    /// report per package in build order.
    ///
    /// The build is tolerant of an incomplete catalog: a dependency that is not
    /// in the catalog does not abort the run — the package that needs it is
    /// reported `deferred` with a "blocked: missing dependency" reason, and the
    /// rest of the plan still runs. A single invocation therefore surfaces the
    /// whole porting backlog for a target rather than stopping at the first gap.
    @discardableResult
    public func build(_ roots: [String]) throws -> [BuildReport] {
        for root in roots where catalog.recipe(for: root) == nil {
            throw BuildError.notInCatalog(root)
        }

        var order: [String] = []
        var visited: Set<String> = []
        var visiting: Set<String> = []
        var blockedBy: [String: String] = [:]   // package -> first missing dependency

        func visit(_ name: String, stack: [String]) throws {
            if visited.contains(name) { return }
            guard let recipe = catalog.recipe(for: name) else { return }
            if visiting.contains(name) {
                throw BuildError.dependencyCycle(stack + [name])
            }
            visiting.insert(name)
            for dep in recipe.metadata.dependencies {
                if catalog.recipe(for: dep) != nil {
                    try visit(dep, stack: stack + [name])
                } else if blockedBy[name] == nil {
                    blockedBy[name] = dep
                }
            }
            visiting.remove(name)
            visited.insert(name)
            order.append(name)
        }

        for root in roots { try visit(root, stack: []) }

        var reports: [BuildReport] = []
        for name in order {
            guard let recipe = catalog.recipe(for: name) else { continue }
            let report: BuildReport
            if let missing = blockedBy[name] {
                report = BuildReport(
                    package: name, target: backend.target,
                    status: .deferred(reason: "blocked: missing dependency '\(missing)'")
                )
            } else {
                report = backend.build(recipe, into: vfs, prefix: prefix)
            }
            if report.status.isBuilt {
                repository.markInstalled(name)
                // Publish the actually-staged files to the store, reading their
                // contents back from the VFS. This works uniformly for static
                // artifacts and scripted builds that produce files at build time.
                if let store, case .built(let stagedPaths) = report.status, !stagedPaths.isEmpty {
                    let artifacts: [BuildArtifact] = stagedPaths.compactMap { path in
                        guard let contents = try? vfs.readString(prefix + "/" + path) else { return nil }
                        return BuildArtifact(path: path, contents: contents)
                    }
                    if !artifacts.isEmpty {
                        try? store.publish(PackageArchive(manifest: recipe.manifest, artifacts: artifacts))
                    }
                }
            }
            reports.append(report)
        }
        return reports
    }
}
