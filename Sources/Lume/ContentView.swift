import SwiftUI
import AppKit
import LumeKit

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
        }
    }
}

/// Chooses the right viewer for the current selection (DocumentRouter-style).
private struct DetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let message = app.errorMessage {
            ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if let url = app.selectedURL {
            VStack(spacing: 0) {
                DocumentTagBar(url: url)
                Divider()
                viewer(for: url)
            }
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc", description: Text("Pick a file in the sidebar."))
        }
    }

    @ViewBuilder
    private func viewer(for url: URL) -> some View {
        if app.selectedKind == .env {
            EnvEditorView()
        } else if ConfigRegistry.format(forFilename: url.lastPathComponent) != nil {
            ConfigEditorView()
        } else {
            switch app.selectedKind {
            case .markdown, .code, .env:
                if app.documentText != nil { EditorView() } else { loading }
            case .pdf:
                PDFViewer(url: url)
            case .image:
                ImageViewer(url: url)
            case .html:
                HTMLViewer(url: url)
            case .previewable, .unsupported:
                QuickLookViewer(url: url)
            }
        }
    }

    private var loading: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
