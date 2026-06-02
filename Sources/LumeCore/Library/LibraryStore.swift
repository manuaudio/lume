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

    /// The user-given label for a path, or nil if none set.
    public func displayName(for path: String) -> String? {
        let name = meta(for: path)?.displayName ?? ""
        return name.isEmpty ? nil : name
    }

    public func files(taggedWith name: String) -> [FileMeta] {
        guard let tag = existingTag(named: name) else { return [] }
        return tag.files
    }

    // MARK: Tags

    /// Fetch a tag by name, creating it if absent.
    private func tag(named name: String) -> Tag {
        if let existing = existingTag(named: name) { return existing }
        let t = Tag(name: name)
        context.insert(t)
        return t
    }

    private func existingTag(named name: String) -> Tag? {
        var d = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == name })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
}
