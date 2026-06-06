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

    var body: some View {
        Section("Groups") {
            if app.tags.isEmpty {
                Text("No groups yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(app.tags, id: \.name) { tag in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.tag(tag.colorIndex))
                            .frame(width: 9, height: 9)
                        Text(tag.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(tag.files.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
