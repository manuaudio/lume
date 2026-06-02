import Foundation
import SwiftData

@MainActor
public final class LibraryStore {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }

    // MARK: Favorites

    public func addFavorite(path: String, kind: FileKind) {
        if favorite(for: path) != nil { return }
        context.insert(Favorite(path: path, kindRaw: String(describing: kind)))
        try? context.save()
    }

    public func removeFavorite(path: String) {
        if let fav = favorite(for: path) { context.delete(fav) ; try? context.save() }
    }

    public func favorites() -> [Favorite] {
        (try? context.fetch(
            FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.dateAdded)])
        )) ?? []
    }

    private func favorite(for path: String) -> Favorite? {
        var d = FetchDescriptor<Favorite>(predicate: #Predicate { $0.path == path })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Metadata (tags + notes)

    public func setMeta(path: String, info: String, tagNames: [String]) {
        let meta = meta(for: path) ?? {
            let m = FileMeta(path: path)
            context.insert(m)
            return m
        }()
        meta.info = info
        meta.tags = tagNames.map { tag(named: $0) }
        try? context.save()
    }

    public func meta(for path: String) -> FileMeta? {
        var d = FetchDescriptor<FileMeta>(predicate: #Predicate { $0.path == path })
        d.fetchLimit = 1
        return try? context.fetch(d).first
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
