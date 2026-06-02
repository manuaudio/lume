import SwiftUI
import SwiftData
import LumeCore

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.dateAdded) private var favorites: [Favorite]
    @Query(sort: \Bookmark.dateAdded) private var bookmarks: [Bookmark]
    @Query(sort: \Tag.name) private var tags: [Tag]

    private var mode: Binding<SidebarMode> {
        Binding(get: { model.sidebarMode }, set: { model.sidebarMode = $0 })
    }

    var body: some View {
        // List holds rows directly (NO Section header): on macOS `.sidebar`
        // style, section headers get a negative leading inset and clip long
        // text. Mini-headers below are plain rows we fully control.
        List {
            if model.sidebarMode == .favorites {
                favoritesContent
            } else {
                browseContent
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("View", selection: mode) {
                    ForEach(SidebarMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    // MARK: Browse — Finder-style Locations (whole filesystem, expandable)

    @ViewBuilder private var browseContent: some View {
        groupHeader("Locations")
        ForEach(bookmarks) { bm in
            FavoriteFolderRow(url: URL(fileURLWithPath: bm.path), model: model)
        }
        .onMove { indices, newOffset in
            var paths = bookmarks.map(\.path)
            paths.move(fromOffsets: indices, toOffset: newOffset)
            model.store?.reorderBookmarks(paths)
        }
        if let root = model.rootFolder, !bookmarks.contains(where: { $0.path == root.path }) {
            FavoriteFolderRow(url: root, model: model)
        }
        if bookmarks.isEmpty && model.rootFolder == nil {
            Text("Use ⌘O or the folder button to open a location.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Favorites — tags + favorited folders/files

    @ViewBuilder private var favoritesContent: some View {
        if !tags.isEmpty {
            groupHeader("Tags")
            ForEach(tags) { tag in
                Label(tag.name, systemImage: "tag")
                    .foregroundStyle(.secondary)
            }
        }

        groupHeader("Favorites")
        if favorites.isEmpty {
            Text("No favorites yet.\nRight-click any file or folder to add it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(favorites) { fav in
                let url = URL(fileURLWithPath: fav.path)
                if fav.kindRaw == "folder" {
                    FavoriteFolderRow(url: url, model: model)
                } else {
                    FileLeafRow(url: url, model: model)
                }
            }
            .onMove { indices, newOffset in
                var paths = favorites.map(\.path)
                paths.move(fromOffsets: indices, toOffset: newOffset)
                model.store?.reorderFavorites(paths)
            }
        }
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
            .padding(.leading, 2)
            .listRowSeparator(.hidden)
    }
}
