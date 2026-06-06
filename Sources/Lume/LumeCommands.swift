import SwiftUI
import AppKit

/// All of Lume's menu-bar commands and keyboard shortcuts in one place.
struct LumeCommands: Commands {
    let app: AppState

    var body: some Commands {
        // File
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!app.isDirty)
        }
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { openFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("New Folder") { app.newFolder() }
                .keyboardShortcut("n", modifiers: [.shift, .command])
                .disabled(app.browseURL == nil)
        }

        // Edit — route Undo/Redo through our file-ops UndoManager.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { app.undoManager.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!app.undoManager.canUndo)
            Button("Redo") { app.undoManager.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!app.undoManager.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Paths") { app.copySelectedPaths() }
                .keyboardShortcut("c", modifiers: [.option, .command])
                .disabled(app.selectedURLs.isEmpty)
        }

        // File actions on the selection
        CommandMenu("File Actions") {
            Button("Reveal in Finder") { app.revealInFinder(app.selectedURLs) }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("Move to Trash") { app.moveToTrash(app.selectedURLs) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.selectedURLs.isEmpty)
            Divider()
            Button("Hide / Unhide") { app.toggleHidden(app.selectedURLs) }
                .keyboardShortcut("h", modifiers: [.shift, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("New Group…") { app.beginNewGroup() }
                .keyboardShortcut("g", modifiers: [.control, .command])
                .disabled(app.library == nil)
        }

        // Go / View
        CommandMenu("Go") {
            Button("Enclosing Folder") { app.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!app.canGoUp)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Hidden Files", isOn: Bindable(app).showBrowserHidden)
                .keyboardShortcut(".", modifiers: [.shift, .command])
            Toggle("Files Only", isOn: Bindable(app).filesOnly)
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { app.openFolder(url) }
    }
}
