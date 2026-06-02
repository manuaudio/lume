import SwiftUI
import SwiftData
import LumeCore

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.dateAdded) private var favorites: [Favorite]
    @Query(sort: \Tag.name) private var tags: [Tag]

    var body: some View {
        List {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { fav in
                        let url = URL(fileURLWithPath: fav.path)
                        Button {
                            model.selectedFile = url
                        } label: {
                            Label {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                            .foregroundStyle(model.selectedFile == url ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { tag in
                        let active = model.activeTagFilter == tag.name
                        Button {
                            model.activeTagFilter = active ? nil : tag.name
                        } label: {
                            Label {
                                Text(tag.name)
                            } icon: {
                                Image(systemName: active ? "tag.fill" : "tag")
                                    .foregroundStyle(active ? Color.accentColor : .secondary)
                            }
                            .foregroundStyle(active ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                if model.tree.isEmpty {
                    Label("No folder open", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    FileTreeView(nodes: model.tree, model: model)
                }
            } header: {
                Text(model.rootFolder?.lastPathComponent ?? "Files")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.visible)
    }
}
