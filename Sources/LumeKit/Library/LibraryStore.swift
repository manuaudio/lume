import Foundation
import SwiftData

@MainActor
public final class LibraryStore {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }

    // MARK: Favorites

    public func addFavorite(path: String, kind: FileKind) {
        if favorite(for: path) != nil { return }
        context.insert(Favorite(path: path, kindRaw: String(describing: kind), sortIndex: favorites().count))
        try? context.save()
    }

    /// Favorite a directory. Folders aren't a `FileKind`, so we persist a
    /// sentinel raw value and branch on it (and on-disk `isDirectory`) at render.
    public func addFavoriteFolder(path: String) {
        if favorite(for: path) != nil { return }
        context.insert(Favorite(path: path, kindRaw: "folder", sortIndex: favorites().count))
        try? context.save()
    }

    /// Persist a new ordering for favorites (drag-to-reorder).
    public func reorderFavorites(_ orderedPaths: [String]) {
        for (i, p) in orderedPaths.enumerated() {
            favorite(for: p)?.sortIndex = i
        }
        try? context.save()
    }

    public func isFavorite(path: String) -> Bool {
        favorite(for: path) != nil
    }

    public func removeFavorite(path: String) {
        if let fav = favorite(for: path) { context.delete(fav) ; try? context.save() }
    }

    public func favorites() -> [Favorite] {
        (try? context.fetch(
            FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    private func favorite(for path: String) -> Favorite? {
        var d = FetchDescriptor<Favorite>(predicate: #Predicate { $0.path == path })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Bookmarks (folders pinned to the top of Browse)

    public func addBookmark(path: String) {
        if bookmark(for: path) != nil { return }
        context.insert(Bookmark(path: path, sortIndex: bookmarks().count))
        try? context.save()
    }

    /// Persist a new ordering for bookmarks (drag-to-reorder).
    public func reorderBookmarks(_ orderedPaths: [String]) {
        for (i, p) in orderedPaths.enumerated() {
            bookmark(for: p)?.sortIndex = i
        }
        try? context.save()
    }

    public func removeBookmark(path: String) {
        if let b = bookmark(for: path) { context.delete(b); try? context.save() }
    }

    public func isBookmarked(path: String) -> Bool { bookmark(for: path) != nil }

    public func bookmarks() -> [Bookmark] {
        (try? context.fetch(
            FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    private func bookmark(for path: String) -> Bookmark? {
        var d = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.path == path })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// One-time migration: every bookmarked folder becomes a folder `Favorite`
    /// (pins unify onto Favorites), then the bookmark table is cleared so this is
    /// idempotent. Returns how many NEW favorites were created.
    @discardableResult
    public func migrateBookmarksToFavorites() -> Int {
        let existing = bookmarks()
        let base = favorites().count
        var created = 0
        for bm in existing {
            if favorite(for: bm.path) == nil {
                context.insert(Favorite(path: bm.path, kindRaw: "folder",
                                        sortIndex: base + created))
                created += 1
            }
            context.delete(bm)
        }
        try? context.save()
        return created
    }

    // MARK: Metadata (tags + notes)

    public func setMeta(path: String, info: String, tagNames: [String], displayName: String = "") {
        let meta = meta(for: path) ?? {
            let m = FileMeta(path: path)
            context.insert(m)
            return m
        }()
        meta.info = info
        meta.displayName = displayName
        // De-duplicate names before resolving Tags so we never try to create two
        // Tags with the same unique `name` in one pass (the second `tag(named:)`
        // can't yet see the first, unsaved one), which would make the save throw
        // and silently drop the metadata.
        var seen = Set<String>()
        let uniqueNames = tagNames.filter { seen.insert($0).inserted }
        meta.tags = uniqueNames.map { tag(named: $0) }
        try? context.save()
    }

    public func meta(for path: String) -> FileMeta? {
        var d = FetchDescriptor<FileMeta>(predicate: #Predicate { $0.path == path })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// Set the hidden flag for each path, upserting `FileMeta` (reusing the
    /// meta-or-insert pattern from `setMeta`) so other metadata is preserved.
    /// Saves once after all paths are updated.
    public func setHidden(_ hidden: Bool, paths: [String]) {
        for path in paths {
            let meta = meta(for: path) ?? {
                let m = FileMeta(path: path)
                context.insert(m)
                return m
            }()
            meta.hidden = hidden
        }
        try? context.save()
    }

    /// All paths currently marked hidden.
    public func hiddenPaths() -> Set<String> {
        let d = FetchDescriptor<FileMeta>(predicate: #Predicate { $0.hidden })
        return Set((try? context.fetch(d))?.map(\.path) ?? [])
    }

    /// The user-given label for a path, or nil if none set.
    public func displayName(for path: String) -> String? {
        let name = meta(for: path)?.displayName ?? ""
        return name.isEmpty ? nil : name
    }

    public func files(taggedWith name: String) -> [FileMeta] {
        guard let tag = existingTag(named: name) else { return [] }
        return tag.files
    }

    /// The set of file paths carrying a given tag (for filtering the browser).
    public func paths(taggedWith name: String) -> Set<String> {
        Set(files(taggedWith: name).map(\.path))
    }

    /// Paths carrying EVERY one of `names` (set intersection) — the All/AND
    /// filter. Empty input returns the empty set (callers skip filtering when
    /// there are no active filters, so we never need "intersection of zero sets =
    /// everything"). A name no file carries empties the result.
    public func paths(taggedWithAll names: Set<String>) -> Set<String> {
        guard let first = names.first else { return [] }
        var result = paths(taggedWith: first)
        for name in names.dropFirst() {
            result.formIntersection(paths(taggedWith: name))
            if result.isEmpty { break }
        }
        return result
    }

    /// Paths carrying ANY of `names` (set union) — the Any/OR filter. Empty input
    /// returns the empty set. Missing names contribute nothing.
    public func paths(taggedWithAny names: Set<String>) -> Set<String> {
        var result = Set<String>()
        for name in names { result.formUnion(paths(taggedWith: name)) }
        return result
    }

    // MARK: Tags

    /// Every tag, sorted by name (also drives color cycling and orphan pruning).
    public func allTags() -> [Tag] {
        (try? context.fetch(
            FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)])
        )) ?? []
    }

    /// The palette index a brand-new tag should receive — cycles through the
    /// palette by current tag count so a fresh library spreads colors. Color
    /// collisions are cosmetic (the user can recolor), so a best-effort spread is
    /// fine; we don't try to guarantee uniqueness across an unsaved batch.
    private func nextColorIndex() -> Int {
        TagPalette.wrap(allTags().count)
    }

    /// The stored palette index for a tag, or 0 if it doesn't exist yet.
    public func colorIndex(forTagNamed name: String) -> Int {
        existingTag(named: name)?.colorIndex ?? 0
    }

    /// Change a tag's palette color. Out-of-range indexes are wrapped.
    public func recolorTag(named name: String, colorIndex: Int) {
        guard let t = existingTag(named: name) else { return }
        t.colorIndex = TagPalette.wrap(colorIndex)
        try? context.save()
    }

    /// Create a brand-new, EMPTY tag (a GROUP with no files yet). Trims the name,
    /// ignores blanks, and is idempotent by name (reuses an existing tag). New
    /// tags get the next cycling palette color, like any tag created via `setMeta`.
    /// Empty tags persist — they are NOT auto-pruned (see the GROUPS design: a
    /// user-created group with zero files is valid).
    public func createEmptyTag(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, existingTag(named: name) == nil else { return }
        context.insert(Tag(name: name, colorIndex: nextColorIndex()))
        try? context.save()
    }

    /// Remove ONE tag from ONE file (the GROUPS "Remove from {group}" action). The
    /// file stays on disk and keeps every other tag; the tag persists even if this
    /// was its last file (empty groups are valid — no auto-prune).
    public func removeTag(named name: String, fromPath path: String) {
        guard let meta = meta(for: path) else { return }
        meta.tags.removeAll { $0.name == name }
        try? context.save()
    }

    /// Delete a tag outright: detach it from every file it tags, then remove it.
    public func deleteTag(named name: String) {
        guard let t = existingTag(named: name) else { return }
        for file in t.files {
            file.tags.removeAll { $0.name == name }
        }
        context.delete(t)
        try? context.save()
    }

    /// Delete every tag no file references. This is the fix for "you can't remove
    /// a tag" — clearing a tag off its last file otherwise leaves a dangling
    /// entry in the sidebar forever. Returns how many tags were pruned.
    @discardableResult
    public func pruneOrphanTags() -> Int {
        let orphans = allTags().filter { $0.files.isEmpty }
        for t in orphans { context.delete(t) }
        if !orphans.isEmpty { try? context.save() }
        return orphans.count
    }

    /// Rename a tag. If `newName` already exists, MERGE: every file on the old
    /// tag is moved onto the existing tag (de-duped) and the old tag is deleted.
    /// Returns false when the source is missing or the name is blank/unchanged.
    @discardableResult
    public func renameTag(named oldName: String, to rawNewName: String) -> Bool {
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName,
              let source = existingTag(named: oldName) else { return false }

        if let target = existingTag(named: newName) {
            // Merge. Snapshot first — we mutate each file's `tags` in the loop.
            let affected = source.files
            for file in affected {
                if !file.tags.contains(where: { $0.name == newName }) {
                    file.tags.append(target)
                }
                file.tags.removeAll { $0.name == oldName }
            }
            context.delete(source)
        } else {
            source.name = newName
        }
        try? context.save()
        return true
    }

    /// Merge several tags into one. Every file on a source tag is re-pointed onto
    /// `survivor` (de-duped), the chosen `colorIndex` (if any) is applied, and the
    /// emptied source tags are pruned. Built on `renameTag` (which already merges
    /// on a name clash) so the per-file de-dup logic lives in exactly one place.
    /// `survivor` need not pre-exist: the first matching source is renamed to it.
    /// Returns true if the survivor exists after the operation.
    @discardableResult
    public func mergeTags(_ names: [String], into survivor: String, colorIndex: Int?) -> Bool {
        // Fold every other named tag onto the survivor. `renameTag` renames when
        // the survivor is absent and merges when it already exists, so iterating
        // sources naturally creates-then-merges.
        for name in names where name != survivor {
            _ = renameTag(named: name, to: survivor)
        }
        if let colorIndex { recolorTag(named: survivor, colorIndex: colorIndex) }
        pruneOrphanTags()
        return existingTag(named: survivor) != nil
    }

    /// Fetch a tag by name, creating it (with the next cycling color) if absent.
    private func tag(named name: String) -> Tag {
        if let existing = existingTag(named: name) { return existing }
        let t = Tag(name: name, colorIndex: nextColorIndex())
        context.insert(t)
        return t
    }

    private func existingTag(named name: String) -> Tag? {
        var d = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == name })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
}
