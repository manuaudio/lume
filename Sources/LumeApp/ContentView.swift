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
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            HSplitView {
                DocumentSurfaceView(model: model)
                    .frame(minWidth: 460)
                    .layoutPriority(1)

                if model.showInfoPanel {
                    InfoPanelView(model: model)
                        .frame(minWidth: 260, idealWidth: 280, maxWidth: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.showInfoPanel)
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
        guard let url = model.selectedFile, let store = model.store else { return }
        let path = url.path
        if store.favorites().contains(where: { $0.path == path }) {
            store.removeFavorite(path: path)
        } else {
            store.addFavorite(path: path, kind: FileKind.detect(filename: url.lastPathComponent))
        }
        refreshFavoriteState()
    }

    private func refreshFavoriteState() {
        guard let url = model.selectedFile, let store = model.store else {
            isFavorited = false
            return
        }
        isFavorited = store.favorites().contains { $0.path == url.path }
    }
}
