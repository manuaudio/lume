import SwiftUI
import AppKit
import LumeKit

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if app.rootURL != nil {
                List {
                    GroupsRegion()
                    FavoritesRegion()
                    OpenFolderRegion()
                }
                .listStyle(.sidebar)
                Divider()
                SidebarFilterBar()
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem {
                Button { openFolder() } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Folder Open", systemImage: "folder.badge.plus")
        } description: {
            Text("Open a folder to start browsing.")
        } actions: {
            Button("Open Folder…") { openFolder() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.openFolder(url)
        }
    }
}

// MARK: - GROUPS

private struct GroupsRegion: View {
    @Environment(AppState.self) private var app
    @State private var creatingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        Section {
            if app.tags.isEmpty {
                Text("Drag files onto a group, or tag from the editor header")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.tags, id: \.name) { tag in
                    GroupHeaderRow(tag: tag)
                    if app.isGroupExpanded(tag.name) {
                        ForEach(app.groupFilePaths[tag.name] ?? [], id: \.self) { path in
                            GroupMemberRow(tagName: tag.name, path: path)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Groups")
                Spacer()
                Button { creatingGroup = true } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Group")
            }
        }
        .alert("New Group", isPresented: $creatingGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                app.createGroup(named: newGroupName)
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
    }
}

/// A tag's GROUP header: expand/collapse, color dot, member count. Drop a file
/// here to tag it; right-click to recolor / rename / delete.
private struct GroupHeaderRow: View {
    let tag: Tag
    @Environment(AppState.self) private var app
    @State private var renaming = false
    @State private var newName = ""
    @State private var dropTargeted = false

    var body: some View {
        Button { app.toggleGroup(tag.name) } label: {
            HStack(spacing: 6) {
                Image(systemName: app.isGroupExpanded(tag.name) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Circle().fill(Color.tag(tag.colorIndex)).frame(width: 9, height: 9)
                Text(tag.name).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(tag.files.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(dropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls { app.addTag(tag.name, toPath: u.path) }
            if !app.isGroupExpanded(tag.name) { app.toggleGroup(tag.name) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Menu("Color") {
                ForEach(0..<TagPalette.count, id: \.self) { i in
                    Button(TagPalette.swatch(at: i).name) {
                        app.recolorGroup(tag.name, colorIndex: i)
                    }
                }
            }
            Button("Rename…") { newName = tag.name; renaming = true }
            Button("Delete Group", role: .destructive) { app.deleteGroup(tag.name) }
        }
        .alert("Rename Group", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { _ = app.renameGroup(tag.name, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renaming to an existing group merges them.")
        }
    }
}

/// A file inside an expanded GROUP. Opens on click; right-click to untag.
private struct GroupMemberRow: View {
    let tagName: String
    let path: String
    @Environment(AppState.self) private var app

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        Button { app.choose(url) } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: 14)
                Image(systemName: symbolName(for: FileKind.detect(filename: url.lastPathComponent)))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(app.displayName(for: url)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            app.selectedURL == url ? Color.accentColor.opacity(0.22) : Color.clear
        )
        .contextMenu {
            Button("Remove from \(tagName)") { app.removeTag(tagName, fromPath: path) }
        }
    }
}

// MARK: - Favorites

private struct FavoritesRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section("Favorites") {
            if app.visibleFavorites.isEmpty {
                Text("Pin files and folders here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.visibleFavorites, id: \.path) { fav in
                    FavoriteRow(favorite: fav)
                }
            }
        }
    }
}

// MARK: - Open Folder (browser)

private struct OpenFolderRegion: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            let children = app.browseChildren
            if children.isEmpty {
                Text(app.browseFilter.isEmpty ? "Empty folder" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(children) { node in
                    BrowserRow(node: node)
                }
            }
        } header: {
            BreadcrumbBar()
        }
    }
}

// MARK: - Breadcrumb

private struct BreadcrumbBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(Array(app.breadcrumb.enumerated()), id: \.element.id) { index, seg in
                    Button(seg.label) { app.navigate(to: seg.url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == app.breadcrumb.count - 1 ? .primary : .secondary)
                    if index < app.breadcrumb.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Filter bar

private struct SidebarFilterBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $app.browseFilter)
                    .textFieldStyle(.plain)
                if !app.browseFilter.isEmpty {
                    Button { app.browseFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                Toggle("Files only", isOn: $app.filesOnly)
                Toggle("Hidden", isOn: $app.showBrowserHidden)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
