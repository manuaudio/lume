import SwiftUI
import AppKit
import LumeKit

/// A row in the Open Folder tree. The disclosure chevron expands a folder inline;
/// a single click selects (and opens a file / expands a folder); a double-click
/// drills the browser root into the folder. ⌘/⇧ click extends the selection.
struct BrowserRow: View {
    let item: AppState.BrowserRowItem
    @Environment(AppState.self) private var app

    private var node: FileNode { item.node }
    private var rowID: String { AppState.browseRowID(node) }

    var body: some View {
        Button {
            let f = NSEvent.modifierFlags
            app.handleRowTap(rowID, command: f.contains(.command), shift: f.contains(.shift)) {
                if node.isDirectory { app.toggleExpanded(node.url) } else { app.choose(node.url) }
            }
        } label: {
            HStack(spacing: 2) {
                // Indent per depth; folders show a disclosure chevron.
                Color.clear.frame(width: CGFloat(item.depth) * 12)
                if node.isDirectory {
                    Image(systemName: app.isExpanded(node.url) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { app.toggleExpanded(node.url) }
                } else {
                    Color.clear.frame(width: 12)
                }
                RowLabel(
                    url: node.url,
                    isDirectory: node.isDirectory,
                    pinned: app.isFavorite(node.url),
                    hidden: app.isHidden(node.url)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if node.isDirectory { app.navigate(to: node.url) } else { app.choose(node.url) }
        })
        .modifier(FileRowActions(url: node.url, rowID: rowID, isDirectory: node.isDirectory))
    }
}

/// A row in the Favorites region. Pinned folders expand inline (the pinned-hidden
/// filter applies); a single click opens a file or toggles a folder; double-click
/// drills the browser into a folder. Drop files here to pin them.
struct FavoriteRow: View {
    let item: AppState.FavoriteRowItem
    @Environment(AppState.self) private var app

    private var url: URL { item.url }
    private var rowID: String { AppState.favoriteURLRowID(url, isDirectory: item.isDirectory) }

    var body: some View {
        Button {
            let f = NSEvent.modifierFlags
            app.handleRowTap(rowID, command: f.contains(.command), shift: f.contains(.shift)) {
                if item.isDirectory { app.toggleFavoriteExpanded(url) } else { app.choose(url) }
            }
        } label: {
            HStack(spacing: 2) {
                Color.clear.frame(width: CGFloat(item.depth) * 12)
                if item.isDirectory {
                    Image(systemName: app.isFavoriteExpanded(url) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { app.toggleFavoriteExpanded(url) }
                } else {
                    Color.clear.frame(width: 12)
                }
                RowLabel(url: url, isDirectory: item.isDirectory,
                         pinned: item.isPinRoot, hidden: app.isHidden(url))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if item.isDirectory { app.navigate(to: url) } else { app.choose(url) }
        })
        .dropDestination(for: URL.self) { urls, _ in app.pinDropped(urls); return !urls.isEmpty }
        .modifier(FileRowActions(url: url, rowID: rowID, isDirectory: item.isDirectory))
    }
}

/// A favorite that lives on a remote source — a leaf jump-point with a source
/// badge (⚡ host for SSH, branch icon + slug for GitHub). Clicking connects to
/// the source if needed, then opens the file (or reroots the tree for a folder).
struct RemoteFavoriteRow: View {
    let fav: RemoteFavorite
    @Environment(AppState.self) private var app

    private var badgeIcon: String {
        fav.sourceKindRaw == "github" ? "arrow.triangle.branch" : "bolt.horizontal"
    }
    private var filename: String { (fav.path as NSString).lastPathComponent }

    var body: some View {
        Button { app.openRemoteFavorite(fav) } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 12)   // align with local rows' chevron gutter
                Image(systemName: fav.isDirectory
                      ? "folder.fill"
                      : symbolName(for: FileKind.detect(filename: filename)))
                    .foregroundStyle(fav.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Label(fav.sourceKey, systemImage: badgeIcon)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Favorites") { app.removeRemoteFavorite(fav) }
        }
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
        if multi {
            Button("Tag \(sel.count) Items…") { app.presentingMultiTag = true }
            Divider()
        }
        Button(multi ? "Copy \(sel.count) Paths" : "Copy Path") { app.copySelectedPaths() }
        Divider()
        Button("New Folder") { app.newFolder() }
        if !multi {
            Button("Rename…") { app.beginRename(url) }
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
