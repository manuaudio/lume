import SwiftUI
import AppKit
import LumeCore

/// The center pane. Switches over `DocumentRouter.viewer(for:)` to host the
/// correct surface for the selected file.
struct DocumentSurfaceView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let url = model.selectedFile, let kind = model.selectedKind {
                VStack(spacing: 0) {
                    if model.showEditorTags {
                        DocumentTagHeader(url: url, model: model)
                    }
                    viewer(for: url, kind: kind)
                        .id(url) // rebuild the surface when the selection changes
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private func viewer(for url: URL, kind: FileKind) -> some View {
        switch DocumentRouter.viewer(for: kind) {
        case .markdownEditor:
            MarkdownEditorView(fileURL: url, editable: true, model: model)
        case .codeViewer:
            CodeView(fileURL: url, model: model)
        case .envEditor:
            EnvView(fileURL: url, model: model)
        case .pdf:
            PDFViewer(fileURL: url)
        case .image:
            ImageViewer(fileURL: url)
        case .quickLook:
            QuickLookViewer(fileURL: url)
        case .html:
            HTMLViewer(fileURL: url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text("No document selected")
                    .font(.title3.weight(.semibold))
                Text("Open a folder, then choose a file from the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.rootFolder == nil {
                Button {
                    openFolderPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            model.openFolder(url)
        }
    }
}
