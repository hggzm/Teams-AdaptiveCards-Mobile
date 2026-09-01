import Foundation

/// Errors surfaced by ``VirtualFileSystem``.
public enum VFSError: Error, Equatable {
    case notFound(String)
    case notADirectory(String)
    case notAFile(String)
    case alreadyExists(String)
    case invalidPath(String)
    case directoryNotEmpty(String)
}

/// A single node in the in-memory tree. Internal — callers interact through
/// ``VirtualFileSystem`` using string paths only.
final class VNode {
    enum Kind { case directory, file, symlink }
    var kind: Kind
    var data: Data
    /// For ``Kind/symlink``: the (absolute or relative) target path.
    var target: String
    var children: [String: VNode]

    init(kind: Kind) {
        self.kind = kind
        self.data = Data()
        self.target = ""
        self.children = [:]
    }
}

/// An in-memory POSIX-like filesystem.
///
/// On stock iOS an app cannot expose a real second root filesystem, so the
/// userland (`$PREFIX`) is modelled here and later mirrored onto the app's
/// sandbox container. Keeping it pure-Swift means the whole layout — and every
/// builtin that reads or writes it — is testable on the desktop.
public final class VirtualFileSystem {
    private let root: VNode

    public init() {
        root = VNode(kind: .directory)
    }

    /// Split an absolute path into normalized components, resolving `.` and `..`.
    public func components(of path: String) throws -> [String] {
        guard path.hasPrefix("/") else { throw VFSError.invalidPath(path) }
        var stack: [String] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(part))
            }
        }
        return stack
    }

    private func node(at comps: [String]) -> VNode? {
        resolve(comps, depth: 0, followFinal: true)?.node
    }

    /// Maximum symlink dereferences before giving up (loop protection).
    private let maxSymlinkDepth = 40

    /// Resolve `comps` to a node, dereferencing symlinks encountered along the
    /// way. When `followFinal` is false, a symlink at the final component is not
    /// dereferenced (used by `readlink`/`remove`/symlink tests).
    private func resolve(_ comps: [String], depth: Int, followFinal: Bool) -> (node: VNode, path: [String])? {
        if depth > maxSymlinkDepth { return nil }
        var cur = root
        var curPath: [String] = []
        for (i, c) in comps.enumerated() {
            guard cur.kind == .directory, let next = cur.children[c] else { return nil }
            let isFinal = i == comps.count - 1
            if next.kind == .symlink && (!isFinal || followFinal) {
                let targetComps = symlinkTargetComponents(next.target, parent: curPath)
                guard let resolved = resolve(targetComps, depth: depth + 1, followFinal: true) else { return nil }
                cur = resolved.node
                curPath = resolved.path
            } else {
                cur = next
                curPath += [c]
            }
        }
        return (cur, curPath)
    }

    /// Normalize a symlink target into absolute components, resolving relative
    /// targets against the link's parent directory.
    private func symlinkTargetComponents(_ target: String, parent: [String]) -> [String] {
        let absolute = target.hasPrefix("/")
            ? target
            : "/" + parent.joined(separator: "/") + "/" + target
        return (try? components(of: absolute)) ?? []
    }

    /// Look up the raw child node named by the final path component, without
    /// dereferencing it if it is a symlink (lstat-like).
    private func linkNode(at path: String) throws -> (parent: VNode, name: String, node: VNode?) {
        let comps = try components(of: path)
        guard let name = comps.last else { throw VFSError.invalidPath(path) }
        let parentComps = Array(comps.dropLast())
        guard let parent = node(at: parentComps), parent.kind == .directory else {
            throw VFSError.notFound("/" + parentComps.joined(separator: "/"))
        }
        return (parent, name, parent.children[name])
    }

    public func exists(_ path: String) -> Bool {
        guard let comps = try? components(of: path) else { return false }
        return node(at: comps) != nil
    }

    public func isDirectory(_ path: String) -> Bool {
        guard let comps = try? components(of: path), let n = node(at: comps) else { return false }
        return n.kind == .directory
    }

    public func isFile(_ path: String) -> Bool {
        guard let comps = try? components(of: path), let n = node(at: comps) else { return false }
        return n.kind == .file
    }

    @discardableResult
    public func makeDirectory(_ path: String, createIntermediates: Bool = true) throws -> Bool {
        let comps = try components(of: path)
        guard !comps.isEmpty else { return false } // "/" already exists
        var cur = root
        for (i, c) in comps.enumerated() {
            if let next = cur.children[c] {
                if next.kind != .directory {
                    throw VFSError.notADirectory("/" + comps[0...i].joined(separator: "/"))
                }
                cur = next
            } else {
                if !createIntermediates && i != comps.count - 1 {
                    throw VFSError.notFound("/" + comps[0..<i].joined(separator: "/"))
                }
                let n = VNode(kind: .directory)
                cur.children[c] = n
                cur = n
            }
        }
        return true
    }

    public func writeFile(_ path: String, data: Data, createIntermediates: Bool = true) throws {
        let comps = try components(of: path)
        guard let name = comps.last else { throw VFSError.invalidPath(path) }
        let parentComps = Array(comps.dropLast())
        if createIntermediates && !parentComps.isEmpty {
            try makeDirectory("/" + parentComps.joined(separator: "/"))
        }
        guard let parent = node(at: parentComps), parent.kind == .directory else {
            throw VFSError.notFound("/" + parentComps.joined(separator: "/"))
        }
        if let existing = parent.children[name], existing.kind == .directory {
            throw VFSError.notAFile(path)
        }
        let f = VNode(kind: .file)
        f.data = data
        parent.children[name] = f
    }

    public func writeFile(_ path: String, string: String) throws {
        try writeFile(path, data: Data(string.utf8))
    }

    public func readFile(_ path: String) throws -> Data {
        let comps = try components(of: path)
        guard let n = node(at: comps) else { throw VFSError.notFound(path) }
        guard n.kind == .file else { throw VFSError.notAFile(path) }
        return n.data
    }

    public func readString(_ path: String) throws -> String {
        String(decoding: try readFile(path), as: UTF8.self)
    }

    public func list(_ path: String) throws -> [String] {
        let comps = try components(of: path)
        guard let n = node(at: comps) else { throw VFSError.notFound(path) }
        guard n.kind == .directory else { throw VFSError.notADirectory(path) }
        return n.children.keys.sorted()
    }

    public func remove(_ path: String, recursive: Bool = false) throws {
        let comps = try components(of: path)
        guard let name = comps.last else { throw VFSError.invalidPath(path) }
        let parentComps = Array(comps.dropLast())
        guard let parent = node(at: parentComps), parent.kind == .directory,
              let target = parent.children[name] else {
            throw VFSError.notFound(path)
        }
        if target.kind == .directory && !target.children.isEmpty && !recursive {
            throw VFSError.directoryNotEmpty(path)
        }
        parent.children[name] = nil
    }

    /// One entry in a recursive walk.
    public struct Entry: Equatable {
        public var path: String
        public var isDirectory: Bool
    }

    /// Recursively enumerate everything under `path` (excluding `path` itself),
    /// in sorted, depth-first order. Used by `find` and by persistence.
    public func walk(_ path: String = "/") throws -> [Entry] {
        let comps = try components(of: path)
        guard let start = node(at: comps) else { throw VFSError.notFound(path) }
        guard start.kind == .directory else { throw VFSError.notADirectory(path) }
        var result: [Entry] = []
        let base = comps.isEmpty ? "" : "/" + comps.joined(separator: "/")
        func recurse(_ node: VNode, _ prefix: String) {
            for name in node.children.keys.sorted() {
                let child = node.children[name]!
                let childPath = prefix + "/" + name
                result.append(Entry(path: childPath, isDirectory: child.kind == .directory))
                if child.kind == .directory { recurse(child, childPath) }
            }
        }
        recurse(start, base)
        return result
    }

    // MARK: Symbolic links

    /// Create a symbolic link at `path` pointing at `target` (absolute or
    /// relative). The link is not required to point at an existing node.
    public func createSymlink(_ path: String, target: String) throws {
        let (parent, name, existing) = try linkNode(at: path)
        if existing != nil { throw VFSError.alreadyExists(path) }
        let link = VNode(kind: .symlink)
        link.target = target
        parent.children[name] = link
    }

    /// True if `path` itself is a symlink (does not follow it).
    public func isSymlink(_ path: String) -> Bool {
        guard let (_, _, node) = try? linkNode(at: path) else { return false }
        return node?.kind == .symlink
    }

    /// Read the target of the symlink at `path`.
    public func readlink(_ path: String) throws -> String {
        let (_, _, node) = try linkNode(at: path)
        guard let node else { throw VFSError.notFound(path) }
        guard node.kind == .symlink else { throw VFSError.notAFile(path) }
        return node.target
    }
}


