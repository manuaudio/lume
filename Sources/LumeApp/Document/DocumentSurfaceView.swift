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
                    // No `.id(url)` here: a stable identity lets each viewer REUSE
                    // its backing NSView across selections (the WebView editor keeps
                    // its loaded CodeMirror page; image/pdf/quicklook/html re-point in
                    // updateNSView; config/env reload via .onChange(of: fileURL)).
                    // Rebuilding per selection cold-booted a ~1.5 MB WebView on every
                    // click — the dominant open-path stall.
                    viewer(for: url, kind: kind)
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
        // Config files with a registered structured format get the structured
        // editor (with a raw toggle), in preference to the read-only CodeView.
        if let format = ConfigRegistry.format(forFilename: url.lastPathComponent) {
            ConfigEditorView(fileURL: url, format: format, model: model)
        } else {
            plainViewer(for: url, kind: kind)
        }
    }

    @ViewBuilder
    private func plainViewer(for url: URL, kind: FileKind) -> some View {
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

    // Native empty state: correct typographic scale, spacing, and centering for
    // free, with the Open Folder call-to-action in the standard actions slot.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Document Selected", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Open a folder, then choose a file from the sidebar.")
        } actions: {
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
