import SwiftUI
import LumeKit

/// A row in the Open Folder browser. Folders drill in; files open in the detail
/// pane. Right-click pins/unpins.
struct BrowserRow: View {
    let node: FileNode
    @Environment(AppState.self) private var app

    var body: some View {
        Button {
            if node.isDirectory { app.navigate(to: node.url) }
            else { app.choose(node.url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder.fill" : symbolName(for: node.kind))
                    .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(app.displayName(for: node.url))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if app.isFavorite(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            app.selectedURL == node.url ? Color.accentColor.opacity(0.22) : Color.clear
        )
        .contextMenu {
            Button(app.isFavorite(node.url) ? "Remove from Favorites" : "Add to Favorites") {
                app.toggleFavorite(node)
            }
        }
    }
}

/// A row in the Favorites region. Files open; folders jump the browser into them.
struct FavoriteRow: View {
    let favorite: Favorite
    @Environment(AppState.self) private var app

    private var url: URL { URL(fileURLWithPath: favorite.path) }
    private var isFolder: Bool { app.favoriteIsFolder(favorite) }

    var body: some View {
        Button {
            if isFolder { app.navigate(to: url) }
            else { app.choose(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFolder ? "folder.fill" : symbolName(for: FileKind.detect(filename: url.lastPathComponent)))
                    .foregroundStyle(isFolder ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(app.displayName(for: url))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            Button("Remove from Favorites") {
                app.library?.removeFavorite(path: favorite.path)
                app.refreshLibrary()
            }
        }
    }
}
