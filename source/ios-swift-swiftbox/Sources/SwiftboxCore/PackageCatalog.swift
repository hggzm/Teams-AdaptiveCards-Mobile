import Foundation

/// An aggregated set of ``BuildRecipe`` values — the swiftbox package catalog.
///
/// The catalog is the bridge between "what Termux ships" and "what swiftbox can
/// build for iOS". It can be seeded from embedded recipes, from individual
/// `build.sh` strings, or by scanning a real `termux-packages` checkout, so the
/// full upstream set can be aggregated on demand. Every recipe it holds is a
/// concrete item on the iOS porting backlog (see ``portingBacklog``).
public final class PackageCatalog {
    public private(set) var recipes: [String: BuildRecipe] = [:]

    public init() {}

    public var count: Int { recipes.count }
    public var names: [String] { recipes.keys.sorted() }

    public func recipe(for name: String) -> BuildRecipe? { recipes[name] }

    public func add(_ recipe: BuildRecipe) {
        recipes[recipe.name] = recipe
    }

    /// Ingest a single Termux-style `build.sh`.
    @discardableResult
    public func ingest(buildScript text: String, name: String, origin: String = "termux") throws -> BuildRecipe {
        let recipe = try RecipeParser.parse(text, name: name, origin: origin)
        add(recipe)
        return recipe
    }

    /// Scan a `termux-packages` checkout and ingest every `build.sh` found under
    /// its `packages/` (and `root-packages/`, `x11-packages/`) directories. This
    /// is how the *complete* upstream catalog is aggregated — point it at a local
    /// clone. Uses only `FileManager`, so it works on macOS, Linux, Windows and
    /// WSL alike.
    @discardableResult
    public func ingestTermuxPackages(root: String, fileManager fm: FileManager = .default) -> [String] {
        var ingested: [String] = []
        let groups = ["packages", "root-packages", "x11-packages"]
        for group in groups {
            let groupPath = (root as NSString).appendingPathComponent(group)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: groupPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: groupPath) else { continue }
            for pkgName in entries {
                let buildScript = (groupPath as NSString)
                    .appendingPathComponent(pkgName)
                    .appending("/build.sh")
                guard fm.fileExists(atPath: buildScript),
                      let data = fm.contents(atPath: buildScript),
                      let text = String(data: data, encoding: .utf8) else { continue }
                if (try? ingest(buildScript: text, name: pkgName, origin: "termux:\(group)")) != nil {
                    ingested.append(pkgName)
                }
            }
        }
        return ingested
    }

    /// A ``PackageRepository`` populated with every catalog manifest, so the
    /// dependency resolver can plan installs across the whole catalog.
    public func makeRepository() -> PackageRepository {
        let repo = PackageRepository()
        for recipe in recipes.values { repo.publish(recipe.manifest) }
        return repo
    }

    /// The packages that cannot yet be built on the host and therefore need an
    /// iOS/native port — the actionable backlog, grouped by why.
    public func portingBacklog() -> [PackageKind: [String]] {
        var backlog: [PackageKind: [String]] = [:]
        for recipe in recipes.values where recipe.kind != .interpreted || recipe.artifacts.isEmpty {
            if recipe.kind == .interpreted && !recipe.artifacts.isEmpty { continue }
            backlog[recipe.kind, default: []].append(recipe.name)
        }
        for key in backlog.keys { backlog[key]?.sort() }
        return backlog
    }
}
