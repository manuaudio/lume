import SwiftUI
import SwiftData
import LumeCore

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.dateAdded) private var favorites: [Favorite]

    private var mode: Binding<SidebarMode> {
        Binding(get: { model.sidebarMode }, set: { model.sidebarMode = $0 })
    }

    var body: some View {
        // List holds rows directly (NO Section header): on macOS `.sidebar`
        // style, section headers get a negative leading inset and clip long
        // text. The folder name lives in the top bar below, which we fully
        // control, so nothing clips.
        List {
            if model.sidebarMode == .favorites {
                favoritesContent
            } else {
                browseContent
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("View", selection: mode) {
                    ForEach(SidebarMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.sidebarMode == .browse, let name = model.rootFolder?.lastPathComponent {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    @ViewBuilder private var browseContent: some View {
        if model.tree.isEmpty {
            Text("No folder open")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            FileTreeView(nodes: model.tree, model: model)
        }
    }

    @ViewBuilder private var favoritesContent: some View {
        if favorites.isEmpty {
            Text("No favorites yet.\nRight-click any file or folder to add it.")
                .foregroundStyle(.secondary)
                .font(.callout)
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
        }
    }
}
