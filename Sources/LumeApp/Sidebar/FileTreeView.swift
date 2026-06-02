import SwiftUI
import LumeCore

/// Recursive disclosure tree for the opened folder. Children are loaded lazily
/// the first time a directory is expanded.
struct FileTreeView: View {
    let nodes: [FileNode]
    let model: AppModel

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DisclosureGroup {
                    FileTreeView(nodes: model.children(of: node), model: model)
                } label: {
                    Label(node.name, systemImage: "folder")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                }
            } else {
                Button {
                    model.selectedFile = node.url
                } label: {
                    FileRow(node: node, isSelected: model.selectedFile == node.url)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: icon(for: node.kind))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(for: node.kind))
        }
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
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
