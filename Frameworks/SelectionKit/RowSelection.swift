import Foundation

/// Pure, view-agnostic selection math over a flat, top-to-bottom ordered list
/// of row ids (the visual order of the sidebar's currently-visible rows).
///
/// These helpers cover both MOUSE clicks (`click`) and KEYBOARD behaviors
/// (plain ↑/↓ move, ⇧↑/⇧↓ extend, ⌘A select all), plus the anchor bookkeeping a
/// contiguous range needs. NOTE: native `List(selection:)` does NOT reliably
/// deliver single clicks in this multi-section, recursively-rendered sidebar —
/// the rows' double-click `.onTapGesture` shadows the List's own click handling,
/// so a single click was dropped entirely. `click` restores that explicitly.
public enum RowSelection {

    /// Move the focused row one step in `order` (down: +1, up: -1), replacing the
    /// selection with the single destination row. Returns the new selection and
    /// the new anchor (the destination). No-op at the ends.
    /// `current` is the row the user is moving FROM (the sole selected / anchor).
    public static func move(from current: String?,
                            in order: [String],
                            by step: Int) -> (selection: Set<String>, anchor: String)? {
        guard !order.isEmpty else { return nil }
        guard let current, let idx = order.firstIndex(of: current) else {
            // Nothing focused yet: land on the first (down) or last (up) row.
            let target = step >= 0 ? order.first! : order.last!
            return ([target], target)
        }
        let next = idx + step
        guard order.indices.contains(next) else { return nil }
        let target = order[next]
        return ([target], target)
    }

    /// Extend a contiguous selection from `anchor` toward `focus + step`.
    /// The selection becomes every row between the anchor and the new focus,
    /// inclusive — exactly Finder's ⇧↑/⇧↓. Returns the new selection and the new
    /// focus (the anchor is unchanged by the caller). No-op at the ends.
    public static func extend(anchor: String,
                              focus: String,
                              in order: [String],
                              by step: Int) -> (selection: Set<String>, focus: String)? {
        guard let anchorIdx = order.firstIndex(of: anchor),
              let focusIdx = order.firstIndex(of: focus) else { return nil }
        let newFocusIdx = focusIdx + step
        guard order.indices.contains(newFocusIdx) else { return nil }
        let lo = min(anchorIdx, newFocusIdx)
        let hi = max(anchorIdx, newFocusIdx)
        return (Set(order[lo...hi]), order[newFocusIdx])
    }

    /// The whole list as a selection (⌘A).
    public static func all(in order: [String]) -> Set<String> { Set(order) }

    /// Resolve a mouse click on `target` into a new selection + anchor/focus.
    /// - ⌘ (`command`): toggle `target`'s membership; the anchor follows an added
    ///   row, and is cleared if the anchor itself was removed.
    /// - ⇧ (`shift`) with a known `anchor`: select the contiguous run from the
    ///   anchor to `target`, inclusive (Finder ⇧-click); `target` becomes focus.
    /// - plain (no modifier): collapse to a single-row selection on `target`,
    ///   which becomes the new anchor/focus. The caller activates that row
    ///   (open file / expand folder).
    /// A ⇧-click with no anchor (or an anchor absent from `order`) falls through
    /// to plain behavior.
    public static func click(target: String,
                             current: Set<String>,
                             anchor: String?,
                             in order: [String],
                             command: Bool,
                             shift: Bool) -> (selection: Set<String>,
                                              anchor: String?,
                                              focus: String?) {
        if command {
            var next = current
            if next.contains(target) {
                next.remove(target)
                let newAnchor = anchor == target ? nil : anchor
                return (next, newAnchor, newAnchor)
            }
            next.insert(target)
            return (next, target, target)
        }
        if shift, let anchor,
           let a = order.firstIndex(of: anchor),
           let b = order.firstIndex(of: target) {
            let lo = min(a, b), hi = max(a, b)
            return (Set(order[lo...hi]), anchor, target)
        }
        return ([target], target, target)
    }

    /// Drop now-hidden FILE rows from a selection after a tag filter changes,
    /// mirroring `FileTreeView.visibleChildren`: directories stay (always
    /// navigable), and a file row survives only if its path is in `allowed`.
    /// Each id is "section|d-or-f|path"; `isDirectory` is the "d"/"f" segment and
    /// `path` is everything after it (paths may contain "|", so split at most
    /// twice). Ids we can't decode are kept (fail open — never silently drop).
    /// Returns the surviving selection plus revalidated anchor/focus (each cleared
    /// to nil if it was dropped). When `allowed` is nil, NOTHING is filtered (no
    /// active filter) and the inputs pass through unchanged.
    public static func revalidate(selection: Set<String>,
                                  anchor: String?,
                                  focus: String?,
                                  allowed: Set<String>?) -> (selection: Set<String>,
                                                             anchor: String?,
                                                             focus: String?) {
        guard let allowed else { return (selection, anchor, focus) }
        func survives(_ id: String) -> Bool {
            let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return true } // undecodable → keep
            if parts[1] == "d" { return true }          // directory → always keep
            return allowed.contains(String(parts[2]))   // file → must be allowed
        }
        let kept = selection.filter(survives)
        let newAnchor = anchor.flatMap { survives($0) ? $0 : nil }
        let newFocus = focus.flatMap { survives($0) ? $0 : nil }
        return (kept, newAnchor, newFocus)
    }

    /// If `selection` forms a single contiguous run within `order`, returns the
    /// (low, high) endpoint row ids of that run (in `order` order). Returns nil
    /// when the selection is empty, has ids absent from `order`, or is split into
    /// two-or-more gaps (non-contiguous). Used to recover a sane keyboard focus
    /// after a native mouse ⇧-click mutates the selection without our anchor/focus
    /// bookkeeping.
    public static func contiguousRunEndpoints(of selection: Set<String>,
                                              in order: [String]) -> (low: String, high: String)? {
        guard !selection.isEmpty else { return nil }
        let indices = selection.compactMap { order.firstIndex(of: $0) }.sorted()
        // Every selected id must exist in `order`…
        guard indices.count == selection.count, let lo = indices.first, let hi = indices.last
        else { return nil }
        // …and the run must be gap-free.
        guard hi - lo + 1 == indices.count else { return nil }
        return (order[lo], order[hi])
    }
}
