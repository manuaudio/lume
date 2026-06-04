import Foundation

/// Pure, view-agnostic selection math over a flat, top-to-bottom ordered list
/// of row ids (the visual order of the sidebar's currently-visible rows).
///
/// Native `List(selection:)` already handles ⌘-click toggle and ⇧-click range
/// for mouse input. These helpers cover the KEYBOARD behaviors (plain ↑/↓ move,
/// ⇧↑/⇧↓ extend, ⌘A select all) where SwiftUI's multi-section, recursively-
/// rendered List gives us no reliable built-in behavior, plus the anchor
/// bookkeeping a contiguous keyboard range needs.
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
}
