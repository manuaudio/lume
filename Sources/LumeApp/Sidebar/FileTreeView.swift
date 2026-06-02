import SwiftUI
import LumeCore

/// Recursive disclosure tree for a folder. File rows are taggable for
/// `List(selection:)` navigation; every row has a favorite context menu.
struct FileTreeView: View {
    let nodes: [FileNode]
    let model: AppModel

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DirectoryRow(node: node, model: model)
            } else {
                FileLeafRow(url: node.url, model: model)
            }
        }
    }
}

/// A selectable file row. Left-click opens it; right-click favorites without
/// changing the open document. Highlight is driven solely by `model.selectedFile`
/// (no native List selection), so exactly one row is ever highlighted — no
/// ghost rows across Favorites/Browse switches.
struct FileLeafRow: View {
    let url: URL
    let model: AppModel

    private var isSelected: Bool { model.selectedFile == url }

    var body: some View {
        Button {
            model.selectedFile = url
        } label: {
            FileRow(url: url, kind: FileKind.detect(filename: url.lastPathComponent))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isSelected ? 0.22 : 0))
                .padding(.horizontal, 6)
        )
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .contextMenu { FavoriteMenu(url: url, isDirectory: false, model: model) }
    }
}

/// A directory in the browse tree. Children are enumerated from disk lazily —
/// only the first time it is expanded — then cached.
struct DirectoryRow: View {
    let node: FileNode
    let model: AppModel

    @State private var isExpanded = false
    @State private var children: [FileNode]?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let children {
                FileTreeView(nodes: children, model: model)
            }
        } label: {
            Label(node.name, systemImage: "folder")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .contextMenu { FavoriteMenu(url: node.url, isDirectory: true, model: model) }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, children == nil { children = model.children(of: node) }
        }
    }
}

/// A favorited folder shown in Favorites mode — expands to its live contents.
struct FavoriteFolderRow: View {
    let url: URL
    let model: AppModel

    @State private var isExpanded = false
    @State private var children: [FileNode]?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let children {
                FileTreeView(nodes: children, model: model)
            }
        } label: {
            Label(url.lastPathComponent, systemImage: "folder.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
                .contextMenu { FavoriteMenu(url: url, isDirectory: true, model: model) }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, children == nil { children = model.children(of: url) }
        }
    }
}

/// A leaf file row: kind-tinted icon + middle-truncated name.
struct FileRow: View {
    let url: URL
    let kind: FileKind

    var body: some View {
        Label {
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: icon(for: kind))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(for: kind))
        }
    }

    private func icon(for kind: FileKind) -> String {
        switch kind {
        case .markdown: return "doc.text"
        case .env: return "key.fill"
        case .pdf: return "doc.richtext"
        case .previewable: return "doc"
        case .html: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    private func tint(for kind: FileKind) -> Color {
        switch kind {
        case .markdown: return .blue
        case .env: return .orange
        case .pdf: return .red
        case .html: return .teal
        case .code: return .purple
        case .previewable, .unsupported: return .secondary
        }
    }
}

/// Shared favorite/unfavorite menu item for files and folders.
struct FavoriteMenu: View {
    let url: URL
    let isDirectory: Bool
    let model: AppModel

    var body: some View {
        let fav = model.isFavorite(url)
        Button(fav ? "Remove from Favorites" : "Add to Favorites",
               systemImage: fav ? "star.slash" : "star") {
            model.toggleFavorite(url, isDirectory: isDirectory)
        }
    }
}
