//
//  Repository+merge.swift
//  SwiftGitX
//
//  Added by hggz/SwiftGitX:windows-msvc-enum-bridging
//
//  Bridges three libgit2 primitives needed for server-side 3-way PR
//  merging without a working directory:
//
//    git_merge_base   -> Repository.mergeBase(_:_:)
//    git_merge_trees  -> Repository.mergeTrees(ancestor:ours:theirs:)
//    git_commit_create + git_index_write_tree_to
//                     -> Repository.createMergeCommit(...)
//
//  The patch surface is intentionally minimal so this branch can keep
//  tracking upstream SwiftGitX cleanly. Default merge options only
//  (recursive, GIT_MERGE_FILE_FAVOR_NORMAL) — caller does not get to
//  pick a favor in this revision.
//

import Foundation
import libgit2

extension Repository {

    // MARK: - Public types

    /// A conflicting side of a merge: index entry stage 1 (ancestor),
    /// 2 (ours), or 3 (theirs).
    public struct MergeConflictSide: Sendable, Equatable {
        /// Object id of the blob at this side. May be `OID.zero` if the
        /// file was absent on this side (e.g. add/add conflict has no
        /// ancestor).
        public let id: OID

        /// Path of the file relative to the repository root.
        public let path: String

        /// File mode (UNIX permissions / git filemode bits).
        public let mode: UInt32
    }

    /// One unresolved conflict produced by a 3-way merge of two trees.
    public struct MergeConflict: Sendable, Equatable {
        /// Path of the conflicting entry. If the path differs across
        /// sides (rename/rename), this is the "ours" path when
        /// available, else "theirs", else "ancestor".
        public let path: String

        /// Common-ancestor side (stage 1). `nil` for add/add conflicts.
        public let ancestor: MergeConflictSide?

        /// Our side (stage 2). `nil` if the file was deleted on our
        /// side.
        public let ours: MergeConflictSide?

        /// Their side (stage 3). `nil` if the file was deleted on
        /// their side.
        public let theirs: MergeConflictSide?
    }

    /// Result of merging two trees against a common ancestor.
    public struct MergeTreeResult: Sendable {
        /// OID of the merged tree, or `nil` if the merge produced any
        /// conflicts. When non-`nil`, the tree is suitable to become
        /// the tree of a 2-parent merge commit.
        public let mergedTreeID: OID?

        /// Conflicts produced by the merge. Empty iff `mergedTreeID`
        /// is non-`nil`.
        public let conflicts: [MergeConflict]

        /// Convenience: `true` iff the merge produced no conflicts.
        public var isClean: Bool { mergedTreeID != nil && conflicts.isEmpty }
    }

    // MARK: - Merge base

    /// Find the best common ancestor of two commits (`git_merge_base`).
    ///
    /// - Parameters:
    ///   - one: First commit OID.
    ///   - two: Second commit OID.
    /// - Returns: The merge-base OID, or `nil` if no common ancestor
    ///   exists (libgit2 returned `GIT_ENOTFOUND`).
    public func mergeBase(_ one: OID, _ two: OID) throws(SwiftGitXError) -> OID? {
        var out = git_oid()
        var oidOne = one.raw
        var oidTwo = two.raw

        let status = git_merge_base(&out, pointer, &oidOne, &oidTwo)
        if status == 0 {
            return OID(raw: out)
        }
        // GIT_ENOTFOUND (-3) is "no merge base" and is not an error
        // condition here — orphan-branch merges are legitimate.
        if Int(status) == SwiftGitXError.Code.notFound.rawValue {
            return nil
        }
        // Anything else: surface as a normal error.
        try SwiftGitXError.check(status, operation: .merge)
        return nil
    }

    // MARK: - Merge trees

    /// Three-way merge of two trees against an optional common
    /// ancestor (`git_merge_trees`). Uses libgit2 defaults
    /// (recursive, `GIT_MERGE_FILE_FAVOR_NORMAL`).
    ///
    /// - Parameters:
    ///   - ancestor: Common-ancestor tree, or `nil` for orphan-branch
    ///     merges (libgit2 treats this as an empty tree on both
    ///     sides).
    ///   - ours: The "destination" tree.
    ///   - theirs: The tree being merged in.
    /// - Returns: A ``MergeTreeResult``. If the merge produced
    ///   conflicts, ``MergeTreeResult/mergedTreeID`` is `nil` and
    ///   ``MergeTreeResult/conflicts`` is non-empty. Otherwise the
    ///   merged tree is written to ODB and its OID returned.
    public func mergeTrees(
        ancestor: Tree?,
        ours: Tree,
        theirs: Tree
    ) throws(SwiftGitXError) -> MergeTreeResult {
        // Look up the three tree pointers. The lookup returns owned
        // pointers that must be freed via git_object_free.
        let oursPointer = try ObjectFactory.lookupObjectPointer(
            oid: ours.id.raw,
            type: GIT_OBJECT_TREE,
            repositoryPointer: pointer
        )
        defer { git_object_free(oursPointer) }

        let theirsPointer = try ObjectFactory.lookupObjectPointer(
            oid: theirs.id.raw,
            type: GIT_OBJECT_TREE,
            repositoryPointer: pointer
        )
        defer { git_object_free(theirsPointer) }

        // Ancestor is optional. If nil, pass NULL straight through.
        let ancestorPointer: OpaquePointer?
        if let ancestor {
            ancestorPointer = try ObjectFactory.lookupObjectPointer(
                oid: ancestor.id.raw,
                type: GIT_OBJECT_TREE,
                repositoryPointer: pointer
            )
        } else {
            ancestorPointer = nil
        }
        defer { if let p = ancestorPointer { git_object_free(p) } }

        // Default merge options (recursive, FILE_FAVOR_NORMAL).
        var opts = git_merge_options()
        try git(operation: .merge) {
            git_merge_options_init(&opts, _u32(GIT_MERGE_OPTIONS_VERSION))
        }

        // Run the merge into a fresh in-memory index.
        let indexPointer = try git(operation: .merge) {
            var index: OpaquePointer?
            let status = git_merge_trees(
                &index,
                pointer,
                ancestorPointer,
                oursPointer,
                theirsPointer,
                &opts
            )
            return (index, status)
        }
        defer { git_index_free(indexPointer) }

        // Collect conflicts (if any).
        let conflicts = try Self.collectConflicts(indexPointer: indexPointer)
        if !conflicts.isEmpty {
            return MergeTreeResult(mergedTreeID: nil, conflicts: conflicts)
        }

        // Conflict-free: persist the index as a tree object in this
        // repo's ODB.
        var treeOID = git_oid()
        try git(operation: .merge) {
            git_index_write_tree_to(&treeOID, indexPointer, pointer)
        }
        return MergeTreeResult(mergedTreeID: OID(raw: treeOID), conflicts: [])
    }

    // MARK: - Merge commit creation

    /// Build a commit pointing at the given tree with the given
    /// parents and (optionally) update a ref to it.
    ///
    /// - Parameters:
    ///   - treeID: OID of the tree (typically from
    ///     ``mergeTrees(ancestor:ours:theirs:)``).
    ///   - parents: Parent commits in order. For a typical 3-way
    ///     merge, pass `[base, head]`.
    ///   - author: Author signature.
    ///   - committer: Committer signature. Pass the same as `author`
    ///     if you don't distinguish the two.
    ///   - message: Commit message (will be terminated with a single
    ///     trailing newline if not already).
    ///   - updatingRef: A fully-qualified ref name (e.g.
    ///     `"refs/heads/main"`) to advance to the new commit, or `nil`
    ///     to leave all refs untouched.
    /// - Returns: OID of the newly created commit.
    @discardableResult
    public func createMergeCommit(
        treeID: OID,
        parents: [Commit],
        author: Signature,
        committer: Signature,
        message: String,
        updatingRef: String?
    ) throws(SwiftGitXError) -> OID {
        // Resolve tree pointer.
        let treePointer = try ObjectFactory.lookupObjectPointer(
            oid: treeID.raw,
            type: GIT_OBJECT_TREE,
            repositoryPointer: pointer
        )
        defer { git_object_free(treePointer) }

        // Resolve parent commit pointers.
        var parentPointers: [OpaquePointer?] = []
        parentPointers.reserveCapacity(parents.count)
        for parent in parents {
            let p = try ObjectFactory.lookupObjectPointer(
                oid: parent.id.raw,
                type: GIT_OBJECT_COMMIT,
                repositoryPointer: pointer
            )
            parentPointers.append(p)
        }
        defer {
            for p in parentPointers { if let p { git_object_free(p) } }
        }

        // Build signatures. These are owned and must be freed.
        let authorPointer = try ObjectFactory.makeSignaturePointer(signature: author)
        defer { git_signature_free(authorPointer) }
        let committerPointer = try ObjectFactory.makeSignaturePointer(signature: committer)
        defer { git_signature_free(committerPointer) }

        // Normalize message to end with a newline (libgit2 doesn't
        // require it, but git tooling expects it).
        let normalizedMessage =
            message.hasSuffix("\n") ? message : message + "\n"

        var oid = git_oid()
        try git(operation: .merge) {
            // Use parentPointers as a contiguous buffer of
            // git_commit*. libgit2 declares the parents argument
            // const, but the Clang importer chooses the mutable
            // pointer form on Windows MSVC, so we use
            // withUnsafeMutableBufferPointer to satisfy both.
            parentPointers.withUnsafeMutableBufferPointer { buf in
                git_commit_create(
                    &oid,
                    pointer,
                    updatingRef,                // const char*; nil = no ref update
                    authorPointer,
                    committerPointer,
                    nil,                        // message_encoding (UTF-8 default)
                    normalizedMessage,
                    treePointer,
                    buf.count,
                    buf.baseAddress
                )
            }
        }
        return OID(raw: oid)
    }

    // MARK: - Internal helpers

    /// Walk the conflict iterator on a freshly-merged index and
    /// produce the public-facing ``MergeConflict`` list. Caller
    /// retains ownership of `indexPointer`.
    private static func collectConflicts(
        indexPointer: OpaquePointer
    ) throws(SwiftGitXError) -> [MergeConflict] {
        // Cheap early-out: libgit2 sets a flag when any high-stage
        // entry is present.
        if git_index_has_conflicts(indexPointer) == 0 {
            return []
        }

        let iterator = try git(operation: .merge) {
            var it: OpaquePointer?
            let status = git_index_conflict_iterator_new(&it, indexPointer)
            return (it, status)
        }
        defer { git_index_conflict_iterator_free(iterator) }

        var conflicts: [MergeConflict] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?

            let status = git_index_conflict_next(
                &ancestor, &ours, &theirs, iterator
            )
            // GIT_ITEROVER is -31 in libgit2.
            if status == -31 { break }
            try SwiftGitXError.check(status, operation: .merge)

            let aSide = ancestor.map(Self.makeSide)
            let oSide = ours.map(Self.makeSide)
            let tSide = theirs.map(Self.makeSide)

            // Pick the most useful path for the public record. ours
            // wins when present (the typical case); fall back through
            // theirs and finally ancestor.
            let path = oSide?.path
                ?? tSide?.path
                ?? aSide?.path
                ?? ""

            conflicts.append(
                MergeConflict(
                    path: path,
                    ancestor: aSide,
                    ours: oSide,
                    theirs: tSide
                )
            )
        }
        return conflicts
    }

    private static func makeSide(
        _ entry: UnsafePointer<git_index_entry>
    ) -> MergeConflictSide {
        let raw = entry.pointee
        let path = String(cString: raw.path)
        // git_index_entry.mode is uint32_t in libgit2 -- bridge via
        // _u32 to absorb the MSVC Int32 import.
        let mode = _u32(raw.mode)
        return MergeConflictSide(
            id: OID(raw: raw.id),
            path: path,
            mode: mode
        )
    }
}

// MARK: - Operation tag

extension SwiftGitXError.Operation {
    /// Operation tag attached to errors raised by the merge bridge.
    public static let merge = Self(rawValue: "merge")
}
