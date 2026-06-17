import Foundation

/// Errors surfaced by ``PackageRepository``.
public enum PackageError: Error, Equatable {
    case unknownPackage(String)
    case missingDependency(package: String, dependency: String)
    case dependencyCycle([String])
    case alreadyInstalled(String)
    case notInstalled(String)
    case requiredBy(package: String, dependent: String)
}

/// An in-memory package index plus an installed set.
///
/// This is the brain of the `pkg` command: it holds available manifests, runs
/// topological dependency resolution, and tracks what is installed. The actual
/// fetch/extract/build steps are delegated to a builder later in the roadmap;
/// for now installation simply marks packages present so the resolver and the
/// command surface can be validated end to end.
public final class PackageRepository {
    public private(set) var available: [String: PackageManifest] = [:]
    public private(set) var installed: Set<String> = []

    public init() {}

    public func publish(_ manifest: PackageManifest) {
        available[manifest.name] = manifest
    }

    public func manifest(for name: String) -> PackageManifest? {
        available[name]
    }

    /// Mark `name` installed directly (used by the builder after staging).
    public func markInstalled(_ name: String) {
        installed.insert(name)
    }

    /// Resolve `roots` and all transitive dependencies into install order
    /// (dependencies first). Throws on unknown packages, missing dependencies,
    /// or cycles.
    public func resolveInstallOrder(for roots: [String]) throws -> [String] {
        var order: [String] = []
        var visiting: Set<String> = []
        var visited: Set<String> = []
        var stack: [String] = []

        func visit(_ name: String) throws {
            if visited.contains(name) { return }
            guard let manifest = available[name] else {
                throw PackageError.unknownPackage(name)
            }
            if visiting.contains(name) {
                throw PackageError.dependencyCycle(stack + [name])
            }
            visiting.insert(name)
            stack.append(name)
            for dep in manifest.dependencies {
                guard available[dep] != nil else {
                    throw PackageError.missingDependency(package: name, dependency: dep)
                }
                try visit(dep)
            }
            stack.removeLast()
            visiting.remove(name)
            visited.insert(name)
            order.append(name)
        }

        for root in roots { try visit(root) }
        return order
    }

    /// Install `roots` and their dependencies. Returns the order packages were
    /// installed in.
    @discardableResult
    public func install(_ roots: [String]) throws -> [String] {
        let order = try resolveInstallOrder(for: roots)
        for name in order { installed.insert(name) }
        return order
    }

    /// Remove a package, refusing if another installed package still depends
    /// on it.
    public func remove(_ name: String) throws {
        guard installed.contains(name) else { throw PackageError.notInstalled(name) }
        for other in installed where other != name {
            if let manifest = available[other], manifest.dependencies.contains(name) {
                throw PackageError.requiredBy(package: name, dependent: other)
            }
        }
        installed.remove(name)
    }
}
