import Foundation

/// Pure, view-agnostic revalidation of the sidebar selection after a GROUP
/// mutation. Group row ids embed the tag NAME (`group|g|<name>`,
/// `groupfile|f|<name>|<path>`), so deleting / renaming / unsharing a tag leaves
/// stale ids in `selectedRowIDs` / anchor / focus — and renaming additionally
/// leaves the OLD name in the expanded-groups set (so the renamed group would
/// collapse). These helpers rewrite all of that consistently. Kept here (no
/// SwiftUI/SwiftData) so `AppModel` just delegates and the logic is unit-tested.
public enum GroupSelection {

    /// Result of a revalidation pass: the new selection, anchor, focus, and the
    /// migrated expanded-groups set (delete/rename mutate it; remove leaves it).
    public struct Result: Equatable {
        public var selection: Set<String>
        public var anchor: String?
        public var focus: String?
        public var expandedGroups: Set<String>
    }

    /// After a tag is DELETED: drop every selected id (and anchor/focus) that
    /// decodes to this tag — both the `.header` row and any `.file` rows — and
    /// prune the name from the expanded set. `selectedFile` is intentionally NOT
    /// touched by callers: the open document is a real file still on disk.
    public static func afterDelete(name: String,
                                   selection: Set<String>,
                                   anchor: String?,
                                   focus: String?,
                                   expandedGroups: Set<String>) -> Result {
        let newSelection = selection.filter { !matches($0, tag: name) }
        var expanded = expandedGroups
        expanded.remove(name)
        return Result(selection: newSelection,
                      anchor: anchor.flatMap { matches($0, tag: name) ? nil : $0 },
                      focus: focus.flatMap { matches($0, tag: name) ? nil : $0 },
                      expandedGroups: expanded)
    }

    /// After a tag is RENAMED `old`→`new` (possibly MERGED into an existing
    /// `new`): rewrite every selected id, anchor, and focus that decodes to `old`
    /// into the equivalent id under `new` (header→header, file→file preserving the
    /// path), and migrate the expanded set old→new. Duplicate ids produced by a
    /// merge collapse harmlessly in the resulting Set.
    public static func afterRename(old: String, new: String,
                                   selection: Set<String>,
                                   anchor: String?,
                                   focus: String?,
                                   expandedGroups: Set<String>) -> Result {
        let newSelection = Set(selection.map { rewrite($0, old: old, new: new) })
        var expanded = expandedGroups
        if expanded.remove(old) != nil { expanded.insert(new) }
        return Result(selection: newSelection,
                      anchor: anchor.map { rewrite($0, old: old, new: new) },
                      focus: focus.map { rewrite($0, old: old, new: new) },
                      expandedGroups: expanded)
    }

    /// After ONE file is REMOVED from ONE group: drop exactly the single
    /// `groupfile|f|<name>|<path>` id from the selection, and nil anchor/focus if
    /// they equal it. The header row and the file's ids under OTHER groups survive.
    public static func afterRemove(path: String, name: String,
                                   selection: Set<String>,
                                   anchor: String?,
                                   focus: String?) -> (selection: Set<String>, anchor: String?, focus: String?) {
        let id = GroupRowID.fileID(tagName: name, path: path)
        return (selection.subtracting([id]),
                anchor == id ? nil : anchor,
                focus == id ? nil : focus)
    }

    // MARK: - Private

    /// True when `id` is a GROUP row (header or file) owned by `tag`.
    private static func matches(_ id: String, tag: String) -> Bool {
        switch GroupRowID.decode(id) {
        case .header(let name): return name == tag
        case .file(let name, _): return name == tag
        case nil: return false
        }
    }

    /// Rewrite a GROUP id owned by `old` into the equivalent id under `new`,
    /// preserving the path for file rows. Non-group ids and ids owned by other
    /// tags pass through unchanged.
    private static func rewrite(_ id: String, old: String, new: String) -> String {
        switch GroupRowID.decode(id) {
        case .header(let name) where name == old:
            return GroupRowID.headerID(tagName: new)
        case .file(let name, let path) where name == old:
            return GroupRowID.fileID(tagName: new, path: path)
        default:
            return id
        }
    }
}
