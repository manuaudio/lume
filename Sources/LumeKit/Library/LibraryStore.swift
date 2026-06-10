import Foundation
import Observation
import SwiftData
import os

/// A persistence save failure, surfaced for the app layer to banner.
/// `LibraryStore` publishes the most recent one via `lastPersistenceError`.
public struct PersistenceFailure: Equatable, Sendable {
    /// The `LibraryStore` operation that failed, e.g. "addFavorite".
    public let operation: String
    /// `localizedDescription` of the underlying SwiftData error.
    public let message: String
    public let date: Date

    public init(operation: String, message: String, date: Date = .now) {
        self.operation = operation
        self.message = message
        self.date = date
    }
}

@MainActor
@Observable
public final class LibraryStore {
    private let context: ModelContext
    private let logger = Logger(subsystem: "com.lume.LumeKit", category: "LibraryStore")

    /// The most recent save failure, or nil. The app layer observes this and
    /// shows a non-fatal banner; `clearPersistenceError()` dismisses it. Only
    /// the LATEST failure is kept — the banner is a "your library may not be
    /// persisting" signal, not an error log (the log is in os.Logger).
    public private(set) var lastPersistenceError: PersistenceFailure?

    public init(context: ModelContext) { self.context = context }

    public func clearPersistenceError() { lastPersistenceError = nil }

    /// Single save funnel: every mutation goes through here so failures are
    /// logged and surfaced instead of silently dropped (audit A2).
    @discardableResult
    private func save(_ operation: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            logger.error("\(operation, privacy: .public) failed to save: \(error.localizedDescription, privacy: .public)")
            lastPersistenceError = PersistenceFailure(operation: operation, message: error.localizedDescription)
            return false
        }
    }

    // MARK: Favorites

    public func addFavorite(path: String, kind: FileKind) {
        if favorite(for: path) != nil { return }
        context.insert(Favorite(path: path, kindRaw: String(describing: kind), sortIndex: favorites().count))
        save("addFavorite")
    }

    /// Favorite a directory. Folders aren't a `FileKind`, so we persist a
    /// sentinel raw value and branch on it (and on-disk `isDirectory`) at render.
    public func addFavoriteFolder(path: String) {
        if favorite(for: path) != nil { return }
        context.insert(Favorite(path: path, kindRaw: "folder", sortIndex: favorites().count))
        save("addFavoriteFolder")
    }

    /// Persist a new ordering for favorites (drag-to-reorder).
    public func reorderFavorites(_ orderedPaths: [String]) {
        for (i, p) in orderedPaths.enumerated() {
            favorite(for: p)?.sortIndex = i
        }
        save("reorderFavorites")
    }

    public func isFavorite(path: String) -> Bool {
        favorite(for: path) != nil
    }

    public func removeFavorite(path: String) {
        if let fav = favorite(for: path) { context.delete(fav); save("removeFavorite") }
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

    // MARK: Bookmarks (legacy — model retained for schema compatibility only)

    /// One-time migration: every bookmarked folder becomes a folder `Favorite`
    /// (pins unify onto Favorites), then the bookmark table is cleared so this is
    /// idempotent. Returns how many NEW favorites were created.
    ///
    /// This is the ONLY remaining `Bookmark` API — the CRUD surface (add/reorder/
    /// remove/isBookmarked/bookmarks) was dead code and is gone. The `@Model`
    /// itself stays in `LumeSchemaV1` so existing stores keep opening; it gets
    /// dropped in a future `LumeSchemaV2` migration stage.
    @discardableResult
    public func migrateBookmarksToFavorites() -> Int {
        let existing = (try? context.fetch(
            FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
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
        save("migrateBookmarksToFavorites")
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
        save("setMeta")
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
        save("setHidden")
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

    // MARK: Path repointing

    /// Re-point every path-keyed row from `oldPath` to `newPath` after a rename
    /// or move on disk, so tags, notes, hidden flags, display names, favorites,
    /// scan roots/canonicals, and bundle members survive the operation.
    ///
    /// Scope: ALL path-keyed columns — `FileMeta.path`, `Favorite.path`,
    /// `Scan.roots`, `Scan.canonicalPath`, `ContextBundle.paths` — because the
    /// orphaning bug is identical for each, and a stale `canonicalPath` is the
    /// worst of them (it feeds the destructive overwrite-all flow). The
    /// vestigial `Bookmark` is excluded: its table is emptied at attach by
    /// `migrateBookmarksToFavorites()`.
    ///
    /// Directory moves repoint descendants too: every stored path is an
    /// absolute POSIX string, so "row is under the moved directory" is exactly
    /// a `oldPath + "/"` prefix match ("/a/bc" is NOT under "/a/b").
    ///
    /// If a row already exists at a destination path (its unique attribute
    /// would collide), the destination row is deleted and the moved row wins —
    /// it carries the user's accumulated metadata.
    public func repointPath(from oldPath: String, to newPath: String) {
        guard !oldPath.isEmpty, !newPath.isEmpty, oldPath != newPath else { return }
        let prefix = oldPath + "/"

        func remapped(_ path: String) -> String? {
            if path == oldPath { return newPath }
            if path.hasPrefix(prefix) { return newPath + path.dropFirst(oldPath.count) }
            return nil
        }

        let metas = (try? context.fetch(FetchDescriptor<FileMeta>(
            predicate: #Predicate { $0.path == oldPath || $0.path.starts(with: prefix) }
        ))) ?? []
        for m in metas {
            guard let target = remapped(m.path) else { continue }
            if let clash = meta(for: target) { context.delete(clash) }
            m.path = target
        }

        let favs = (try? context.fetch(FetchDescriptor<Favorite>(
            predicate: #Predicate { $0.path == oldPath || $0.path.starts(with: prefix) }
        ))) ?? []
        for f in favs {
            guard let target = remapped(f.path) else { continue }
            if let clash = favorite(for: target) { context.delete(clash) }
            f.path = target
        }

        for scan in scans() {
            let roots = scan.roots.map { remapped($0) ?? $0 }
            if roots != scan.roots { scan.roots = roots }
            if let canonical = scan.canonicalPath, let target = remapped(canonical) {
                scan.canonicalPath = target
            }
        }
        for bundle in bundles() {
            let paths = bundle.paths.map { remapped($0) ?? $0 }
            if paths != bundle.paths { bundle.paths = paths }
        }

        save("repointPath")
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
        save("recolorTag")
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
        save("createEmptyTag")
    }

    /// Remove ONE tag from ONE file (the GROUPS "Remove from {group}" action). The
    /// file stays on disk and keeps every other tag; the tag persists even if this
    /// was its last file (empty groups are valid — no auto-prune).
    public func removeTag(named name: String, fromPath path: String) {
        guard let meta = meta(for: path) else { return }
        meta.tags.removeAll { $0.name == name }
        save("removeTag")
    }

    /// Delete a tag outright: detach it from every file it tags, then remove it.
    public func deleteTag(named name: String) {
        guard let t = existingTag(named: name) else { return }
        for file in t.files {
            file.tags.removeAll { $0.name == name }
        }
        context.delete(t)
        save("deleteTag")
    }

    /// Delete every tag no file references. This is the fix for "you can't remove
    /// a tag" — clearing a tag off its last file otherwise leaves a dangling
    /// entry in the sidebar forever. Returns how many tags were pruned.
    @discardableResult
    public func pruneOrphanTags() -> Int {
        let orphans = allTags().filter { $0.files.isEmpty }
        for t in orphans { context.delete(t) }
        if !orphans.isEmpty { save("pruneOrphanTags") }
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
        save("renameTag")
        return true
    }

    /// Merge several tags into one. Every file on a source tag is re-pointed onto
    /// `survivor` (de-duped), the chosen `colorIndex` (if any) is applied, and the
    /// source tags are removed by `renameTag` itself (its merge branch deletes the
    /// merged-away source). Built on `renameTag` (which already merges on a name
    /// clash) so the per-file de-dup logic lives in exactly one place.
    /// `survivor` need not pre-exist: the first matching source is renamed to it.
    /// No pruning happens here: unrelated empty tags are untouched, and the
    /// survivor persists even when the merge result has zero files (GROUPS
    /// design, see `createEmptyTag`: empty groups are valid — no auto-prune).
    /// Returns true if the survivor exists after the operation.
    @discardableResult
    public func mergeTags(_ names: [String], into survivor: String, colorIndex: Int?) -> Bool {
        // Fold every other named tag onto the survivor. `renameTag` renames when
        // the survivor is absent and merges when it already exists, so iterating
        // sources naturally creates-then-merges — and deletes each source.
        for name in names where name != survivor {
            _ = renameTag(named: name, to: survivor)
        }
        if let colorIndex { recolorTag(named: survivor, colorIndex: colorIndex) }
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

    // MARK: - Scans

    @discardableResult
    public func addScan(name: String, patterns: [String], roots: [String]) -> Scan {
        let scan = Scan(name: name, patterns: patterns, roots: roots, sortIndex: scans().count)
        context.insert(scan)
        save("addScan")
        return scan
    }

    public func scans() -> [Scan] {
        (try? context.fetch(
            FetchDescriptor<Scan>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    public func updateScan(_ scan: Scan, name: String, patterns: [String], roots: [String]) {
        scan.name = name
        scan.patterns = patterns
        scan.roots = roots
        save("updateScan")
    }

    public func removeScan(_ scan: Scan) {
        context.delete(scan)
        save("removeScan")
    }

    public func setCanonical(_ path: String?, for scan: Scan) {
        scan.canonicalPath = path
        save("setCanonical")
    }

    // MARK: - Bundles

    @discardableResult
    public func addBundle(name: String, paths: [String]) -> ContextBundle {
        let bundle = ContextBundle(name: name, paths: paths, sortIndex: bundles().count)
        context.insert(bundle)
        save("addBundle")
        return bundle
    }

    public func bundles() -> [ContextBundle] {
        (try? context.fetch(
            FetchDescriptor<ContextBundle>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    public func renameBundle(_ bundle: ContextBundle, to name: String) {
        bundle.name = name
        save("renameBundle")
    }

    public func setBundlePaths(_ paths: [String], for bundle: ContextBundle) {
        bundle.paths = paths
        save("setBundlePaths")
    }

    public func removeBundle(_ bundle: ContextBundle) {
        context.delete(bundle)
        save("removeBundle")
    }
}
