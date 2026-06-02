import SwiftUI
import SwiftData
import LumeCore

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.sortIndex) private var favorites: [Favorite]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var allMeta: [FileMeta]

    /// path → custom display name (non-empty only), kept reactive via @Query.
    private var names: [String: String] {
        Dictionary(uniqueKeysWithValues:
            allMeta.filter { !$0.displayName.isEmpty }.map { ($0.path, $0.displayName) })
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedRowID }, set: { model.selectedRowID = $0 })
    }

    var body: some View {
        List(selection: selection) {
            pinnedSection
            if !tags.isEmpty { tagsSection }
            browserSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { filesOnlyBar }
        .onChange(of: model.selectedRowID) { _, id in openIfFile(id) }
    }

    // MARK: Files-only toggle

    private var filesOnlyBar: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.filesOnly },
                                 set: { model.filesOnly = $0 })) {
                Label("Files only", systemImage: "doc")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Pinned

    @ViewBuilder private var pinnedSection: some View {
        Section("Pinned") {
            if favorites.isEmpty {
                Text("Right-click any file or folder to pin it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(favorites) { fav in
                    let url = URL(fileURLWithPath: fav.path)
                    SidebarItemRow(url: url,
                                   isDirectory: fav.kindRaw == "folder",
                                   section: .pinned, depth: 0,
                                   model: model, names: names)
                        .tag(SidebarRow(url: url, isDirectory: fav.kindRaw == "folder",
                                        section: .pinned).id)
                }
                .onMove { indices, newOffset in
                    var paths = favorites.map(\.path)
                    paths.move(fromOffsets: indices, toOffset: newOffset)
                    model.store?.reorderFavorites(paths)
                }
            }
        }
    }

    // MARK: Tags (clickable filters)

    @ViewBuilder private var tagsSection: some View {
        Section("Tags") {
            ForEach(tags) { tag in
                let active = model.activeTagFilter == tag.name
                Label(tag.name, systemImage: active ? "tag.fill" : "tag")
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.activeTagFilter = active ? nil : tag.name
                    }
            }
        }
    }

    // MARK: Browser

    @ViewBuilder private var browserSection: some View {
        Section {
            if let root = model.browseRoot {
                FileTreeView(parent: root, model: model, names: names, depth: 0)
            }
        } header: {
            breadcrumb
        }
    }

    private var breadcrumb: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let segs = model.browseRoot.map { Breadcrumb.segments(for: $0, home: home) } ?? []
        return HStack(spacing: 4) {
            Button { model.drillUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .help("Go up (⌘↑)")
            ForEach(Array(segs.enumerated()), id: \.element.id) { i, seg in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(seg.label) { model.drillInto(seg.url) }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .foregroundStyle(i == segs.count - 1 ? .primary : .secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    // MARK: Selection → open files

    private func openIfFile(_ id: String?) {
        guard let id, let row = decode(id), !row.isDirectory else { return }
        model.selectedFile = row.url
    }

    /// "section|/path" → (url, isDirectory) without needing the source list.
    private func decode(_ id: String) -> (url: URL, isDirectory: Bool)? {
        guard let bar = id.firstIndex(of: "|") else { return nil }
        let path = String(id[id.index(after: bar)...])
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return (url, isDir.boolValue)
    }
}
