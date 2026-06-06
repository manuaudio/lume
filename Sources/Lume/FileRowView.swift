import SwiftUI
import AppKit
import LumeKit

/// A row in the Open Folder browser. Folders drill in; files open. ⌘/⇧ click
/// extends the multi-selection.
struct BrowserRow: View {
    let node: FileNode
    @Environment(AppState.self) private var app

    private var rowID: String { AppState.browseRowID(node) }

    var body: some View {
        Button {
            let f = NSEvent.modifierFlags
            app.handleRowTap(rowID, command: f.contains(.command), shift: f.contains(.shift)) {
                if node.isDirectory { app.navigate(to: node.url) } else { app.choose(node.url) }
            }
        } label: {
            RowLabel(
                url: node.url,
                isDirectory: node.isDirectory,
                pinned: app.isFavorite(node.url),
                hidden: app.isHidden(node.url),
                showsChevron: node.isDirectory
            )
        }
        .buttonStyle(.plain)
        .modifier(FileRowActions(url: node.url, rowID: rowID, isDirectory: node.isDirectory))
    }
}

/// A row in the Favorites region. Files open; folders jump the browser into them.
struct FavoriteRow: View {
    let favorite: Favorite
    @Environment(AppState.self) private var app

    private var url: URL { URL(fileURLWithPath: favorite.path) }
    private var isFolder: Bool { app.favoriteIsFolder(favorite) }
    private var rowID: String { AppState.favoriteRowID(favorite, isFolder: isFolder) }

    var body: some View {
        Button {
            let f = NSEvent.modifierFlags
            app.handleRowTap(rowID, command: f.contains(.command), shift: f.contains(.shift)) {
                if isFolder { app.navigate(to: url) } else { app.choose(url) }
            }
        } label: {
            RowLabel(url: url, isDirectory: isFolder,
                     pinned: false, hidden: app.isHidden(url), showsChevron: false)
        }
        .buttonStyle(.plain)
        .modifier(FileRowActions(url: url, rowID: rowID, isDirectory: isFolder))
    }
}

/// Shared row label: icon + display name (+ optional pin / chevron markers).
struct RowLabel: View {
    let url: URL
    let isDirectory: Bool
    var pinned: Bool = false
    var hidden: Bool = false
    var showsChevron: Bool = false
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDirectory ? "folder.fill" : symbolName(for: FileKind.detect(filename: url.lastPathComponent)))
                .foregroundStyle(isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(app.displayName(for: url))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(hidden ? .secondary : .primary)
            Spacer(minLength: 4)
            if pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            if hidden {
                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary)
            }
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Drag-to-tag, multi-selection highlight, and the file-ops context menu shared
/// by every file/folder row (browser, favorites, group members).
struct FileRowActions<Extra: View>: ViewModifier {
    let url: URL
    let rowID: String
    let isDirectory: Bool
    @ViewBuilder var extraMenu: () -> Extra
    @Environment(AppState.self) private var app
    @State private var renaming = false
    @State private var renameText = ""
    @State private var settingDisplayName = false
    @State private var displayNameText = ""

    init(url: URL, rowID: String, isDirectory: Bool,
         @ViewBuilder extraMenu: @escaping () -> Extra = { EmptyView() }) {
        self.url = url
        self.rowID = rowID
        self.isDirectory = isDirectory
        self.extraMenu = extraMenu
    }

    func body(content: Content) -> some View {
        content
            .draggable(url)
            .listRowBackground(
                (app.isRowSelected(rowID) || app.selectedURL == url)
                    ? Color.accentColor.opacity(0.22) : Color.clear
            )
            .contextMenu { menu }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                Button("Rename") { app.rename(url, to: renameText) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Display Name", isPresented: $settingDisplayName) {
                TextField("Display name (blank to clear)", text: $displayNameText)
                Button("Set") { app.setDisplayName(url, to: displayNameText) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A label shown in Lume only — the file on disk is not renamed.")
            }
    }

    @ViewBuilder private var menu: some View {
        let sel = app.selectedURLs
        let multi = sel.count > 1

        extraMenu()
        Button(multi ? "Copy \(sel.count) Paths" : "Copy Path") { app.copySelectedPaths() }
        Divider()
        Button("New Folder") { app.newFolder() }
        if !multi {
            Button("Rename…") { renameText = url.lastPathComponent; renaming = true }
            Button("Duplicate") { app.duplicate(url) }
            Button("Set Display Name…") {
                displayNameText = app.library?.displayName(for: url.path) ?? ""
                settingDisplayName = true
            }
            Button(app.isFavorite(url) ? "Remove from Favorites" : "Add to Favorites") {
                app.toggleFavorite(url: url, isDirectory: isDirectory)
            }
        }
        Button(app.isHidden(url) ? "Unhide" : "Hide") {
            app.toggleHidden(multi ? sel : [url])
        }
        Divider()
        Button("Reveal in Finder") { app.revealInFinder(multi ? sel : [url]) }
        Button("Move to Trash", role: .destructive) { app.moveToTrash(multi ? sel : [url]) }
    }
}
