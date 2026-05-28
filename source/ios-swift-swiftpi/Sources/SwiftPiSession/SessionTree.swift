// SessionTree — pure functions over a list of `SessionEntry` values.
//
// A session file is a flat append-only list of entries, but conceptually
// it is a tree because each row references its parent. Branching
// happens when two messages share the same parent id (e.g. the user
// regenerated an assistant response). `SessionTree` exposes the small
// set of read-only operations needed by the agent loop and the CLI:
//
//   - `walkToTip(entries:tipID:)` — produce the linear list of entries
//     from the root to `tipID`, in chronological order.
//   - `tipsForBranch(entries:)` — find every leaf id; useful for
//     "did the user fork the conversation?" UI.
//   - `lastTip(entries:)` — return the id of the most recent leaf as
//     a sensible default tip.

import Foundation
import SwiftPiCore

public enum SessionTree {
    /// Walk from the root to the entry whose id equals `tipID`,
    /// returning the ordered list of entries on that path. The walk
    /// climbs parent pointers; if any link breaks (e.g. a missing
    /// parent reference), the function throws.
    public static func walkToTip(
        entries: [SessionEntry],
        tipID: String
    ) throws -> [SessionEntry] {
        var index: [String: SessionEntry] = [:]
        for entry in entries {
            if let id = entry.id {
                index[id] = entry
            }
        }
        guard let tip = index[tipID] else {
            throw SwiftPiError.io("tip id not found in session: \(tipID)")
        }

        // Climb parent pointers, collecting entries on the way up.
        var collected: [SessionEntry] = [tip]
        var seen: Set<String> = [tipID]
        var cursor: SessionEntry = tip
        while let parentID = cursor.parent {
            if seen.contains(parentID) {
                throw SwiftPiError.io(
                    "cycle detected in session tree at \(parentID)"
                )
            }
            guard let parent = index[parentID] else {
                throw SwiftPiError.io(
                    "broken parent reference: \(parentID) (referenced by \(cursor.id ?? "?"))"
                )
            }
            collected.append(parent)
            seen.insert(parentID)
            cursor = parent
        }
        return collected.reversed()
    }

    /// Every leaf id in the session tree, i.e. every entry whose id is
    /// not the parent of any other entry. The result is ordered by the
    /// position of each leaf in `entries` (oldest leaf first), which
    /// makes deterministic test fixtures easy to write.
    public static func tipsForBranch(entries: [SessionEntry]) -> [String] {
        var parentSet: Set<String> = []
        for entry in entries {
            if let parent = entry.parent {
                parentSet.insert(parent)
            }
        }
        var tips: [String] = []
        for entry in entries {
            guard let id = entry.id else { continue }
            if !parentSet.contains(id) {
                tips.append(id)
            }
        }
        return tips
    }

    /// The id of the most recent leaf — the last `id` in append-order
    /// that no later entry references as a parent. Returns nil for
    /// a header-only / empty session.
    public static func lastTip(entries: [SessionEntry]) -> String? {
        tipsForBranch(entries: entries).last
    }

    /// Pull just the Message rows from a `walkToTip` result, in turn order.
    /// Convenience for the agent loop: it usually only cares about the
    /// conversation, not the `session` / `model_change` / `compaction`
    /// rows interspersed with it.
    public static func messages(on path: [SessionEntry]) -> [Message] {
        var out: [Message] = []
        for entry in path {
            if case .message(let m) = entry {
                out.append(m)
            }
        }
        return out
    }
}
