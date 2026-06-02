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
            // Controlled HStack instead of `.inspector`: the document pane is
            // flexible and the info panel a fixed trailing width, so the layout
            // always compresses to fit the window — no overflow/clipping when
            // the window isn't maximized.
            HStack(spacing: 0) {
                DocumentSurfaceView(model: model)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                if model.showInfoPanel {
                    Divider()
                    InfoPanelView(model: model)
                        .frame(width: 264)
                        .frame(maxHeight: .infinity)
                }
            }
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

                Spacer()

                Button {
                    withAnimation { model.showInfoPanel.toggle() }
                } label: {
                    Label("Info", systemImage: "sidebar.trailing")
                }
                .help("Toggle the info panel")
                .symbolVariant(model.showInfoPanel ? .fill : .none)
            }
        }
        .onAppear {
            model.libraryContext = context
            model.seedDefaultBookmarksIfNeeded()
            model.applyLaunchEnvironment()
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
