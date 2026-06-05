import SwiftUI
import SwiftData
import AppKit
import LumeCore

struct ContentView: View {
    @State private var model = AppModel()
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @State private var isFavorited = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DocumentSurfaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(subtitle)
        .focusedValue(\.appModel, model)
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

                Button {
                    model.showEditorTags.toggle()
                } label: {
                    Label("Tags", systemImage: model.showEditorTags ? "tag.fill" : "tag")
                }
                .help(model.showEditorTags ? "Hide the document tag header" : "Show the document tag header")
            }
        }
        .onAppear {
            model.libraryContext = context
            model.undoManager = undoManager
            model.seedAndMigratePins()
            model.applyLaunchEnvironment()
        }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onReceive(NotificationCenter.default.publisher(for: .lumeOpenFolder)) { _ in
            openFolderPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumeRename)) { _ in model.renameSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .lumePin)) { _ in model.pinSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeDrillUp)) { _ in model.drillUp() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeOpenOrDrill)) { _ in model.openOrDrillSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeNewFolder)) { _ in model.newFolder() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeDuplicate)) { _ in model.duplicate() }
        .onReceive(NotificationCenter.default.publisher(for: .lumeTrash)) { _ in model.trash() }
        .onChange(of: model.selectedFile) { _, _ in
            refreshFavoriteState()
        }
    }

    /// Title-bar title: the open document's name, else the browse-root folder.
    private var windowTitle: String {
        if let file = model.selectedFile { return file.lastPathComponent }
        return model.browseRoot?.lastPathComponent ?? "Lume"
    }

    /// Title-bar subtitle: the open file's folder (or the browse root), shown
    /// with a leading ~ like Finder's path bar.
    private var subtitle: String {
        let url = model.selectedFile?.deletingLastPathComponent() ?? model.browseRoot
        guard let path = url?.path else { return "" }
        return (path as NSString).abbreviatingWithTildeInPath
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
