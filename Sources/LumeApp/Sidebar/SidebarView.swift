import SwiftUI
import SwiftData
import LumeCore

struct SidebarView: View {
    let model: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.sortIndex) private var favorites: [Favorite]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var allMeta: [FileMeta]

    @FocusState private var filterFocused: Bool

    /// path → custom display name (non-empty only), kept reactive via @Query.
    private var names: [String: String] {
        Dictionary(uniqueKeysWithValues:
            allMeta.filter { !$0.displayName.isEmpty }.map { ($0.path, $0.displayName) })
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedRowID }, set: { model.selectedRowID = $0 })
    }

    private var filter: Binding<String> {
        Binding(get: { model.browseFilter }, set: { model.browseFilter = $0 })
    }

    var body: some View {
        List(selection: selection) {
            pinnedSection
            if !tags.isEmpty { tagsSection }
            browserSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { topBar }
        .onChange(of: model.selectedRowID) { _, id in openIfFile(id) }
        // List-scoped keys: these only fire when the List — not a text field —
        // is first responder, so they never interfere with the filter/rename/
        // notes editors. Each returns `.handled` only when it acts.
        .background(QLHost(controller: QuickLook.shared))
        .onKeyPress(.init("/")) { filterFocused = true; return .handled }
        .onKeyPress(.space) {
            guard let id = model.selectedRowID,
                  let row = SidebarRow.decode(id), !row.isDirectory else { return .ignored }
            QuickLook.shared.show(row.url)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let id = model.selectedRowID,
                  let row = SidebarRow.decode(id), row.isDirectory else { return .ignored }
            model.expandedPaths.insert(row.url.path)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let id = model.selectedRowID,
                  let row = SidebarRow.decode(id), row.isDirectory,
                  model.expandedPaths.contains(row.url.path) else { return .ignored }
            model.expandedPaths.remove(row.url.path)
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumeFocusFilter)) { _ in
            filterFocused = true
        }
    }

    // MARK: Top bar — filter field + files-only toggle

    private var topBar: some View {
        VStack(spacing: 6) {
            filterField
            HStack {
                Toggle(isOn: Binding(get: { model.filesOnly },
                                     set: { model.filesOnly = $0 })) {
                    Label("Files only", systemImage: "doc")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter…", text: filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onExitCommand { filterFocused = false }
            if !model.browseFilter.isEmpty {
                Button {
                    model.browseFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
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
        guard let id, let row = SidebarRow.decode(id), !row.isDirectory else { return }
        model.selectedFile = row.url
    }
}
