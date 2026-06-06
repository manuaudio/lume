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

/// Chooses the right detail surface for the current selection.
private struct DetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let message = app.errorMessage {
            ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if app.selectedURL == nil {
            ContentUnavailableView("No File Selected", systemImage: "doc", description: Text("Pick a file in the sidebar."))
        } else if app.selectedKind == .other {
            NonTextDetailView()
        } else {
            EditorView()
        }
    }
}

/// Placeholder for binary/unknown files (real viewers are a later increment).
private struct NonTextDetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(app.selectedURL?.lastPathComponent ?? "").font(.headline)
            Button("Open in Default App") {
                if let url = app.selectedURL { NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
