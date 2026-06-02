import SwiftUI
import SwiftData
import AppKit
import LumeCore

struct ContentView: View {
    @State private var model = AppModel()
    @Environment(\.modelContext) private var context

    @State private var isFavorited = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DocumentSurfaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.rootFolder?.lastPathComponent ?? "Lume")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openFolderPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open a working folder")

                Button {
                    toggleFavorite()
                } label: {
                    Label("Favorite", systemImage: isFavorited ? "star.fill" : "star")
                }
                .help(isFavorited ? "Remove from Favorites" : "Add to Favorites")
                .disabled(model.selectedFile == nil)

            }
        }
        .onAppear {
            model.libraryContext = context
            model.seedDefaultBookmarksIfNeeded()
            model.applyLaunchEnvironment()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumeOpenFolder)) { _ in
            openFolderPanel()
        }
        .onChange(of: model.selectedFile) { _, _ in
            refreshFavoriteState()
        }
    }

    // MARK: Actions

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to work in"
        if panel.runModal() == .OK, let url = panel.url {
            model.openFolder(url)
        }
    }

    private func toggleFavorite() {
        guard let url = model.selectedFile else { return }
        model.toggleFavorite(url, isDirectory: false)
        refreshFavoriteState()
    }

    private func refreshFavoriteState() {
        isFavorited = model.selectedFile.map { model.isFavorite($0) } ?? false
    }
}
