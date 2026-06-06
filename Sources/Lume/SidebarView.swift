import SwiftUI
import AppKit
import LumeKit

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if app.rootURL != nil {
                List(selection: $app.selectedURL) {
                    ForEach(app.rootChildren) { node in
                        FileRowView(node: node)
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "folder.badge.plus")
                } description: {
                    Text("Open a folder to start browsing.")
                } actions: {
                    Button("Open Folder…") { openFolder() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { openFolder() } label: {
                    Label("Open Folder", systemImage: "folder")
                }
            }
        }
        .onChange(of: app.selectedURL) { _, url in
            guard let url else { return }
            Task { await app.select(url) }
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
