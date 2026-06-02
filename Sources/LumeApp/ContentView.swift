import SwiftUI
import SwiftData
import AppKit
import LumeCore

struct ContentView: View {
    @State private var model = AppModel()
    @Environment(\.modelContext) private var context

    @State private var isFavorited = false

    private var showInfo: Binding<Bool> {
        Binding(get: { model.showInfoPanel }, set: { model.showInfoPanel = $0 })
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 420)
        } detail: {
            DocumentSurfaceView(model: model)
                .frame(minWidth: 260, minHeight: 280)
                // Native inspector: a collapsible trailing panel that resizes
                // gracefully and never chops the document at narrow widths.
                .inspector(isPresented: showInfo) {
                    InfoPanelView(model: model)
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 360)
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
