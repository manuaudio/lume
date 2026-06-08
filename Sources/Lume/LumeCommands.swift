import SwiftUI
import AppKit
import LumeKit

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

        // Edit — Undo/Redo route through the file-ops UndoManager.
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
            Button("Duplicate") { app.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(app.selectedURLs.isEmpty)
            Button("Move to Trash") { app.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.selectedURLs.isEmpty)
        }

        // Navigate
        CommandMenu("Navigate") {
            Button("Open / Drill In") { app.openOrDrillSelected() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Go Up") { app.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!app.canGoUp)
            Button("Find in Sidebar") { app.requestFilterFocus() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Rename…") { app.beginRename() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.renameTargetURL == nil)
            Button("Pin / Unpin") { app.pinSelection() }
                .keyboardShortcut("p", modifiers: [.control, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("Reveal in Finder") { app.revealInFinder(app.selectedURLs) }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("Hide / Unhide") { app.toggleHidden(app.selectedURLs) }
                .keyboardShortcut("h", modifiers: [.shift, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("New Group…") { app.beginNewGroup() }
                .keyboardShortcut("g", modifiers: [.control, .command])
                .disabled(app.library == nil)
        }

        // Context
        CommandMenu("Context") {
            Button("Copy as Context") { app.copyAsContext(urls: app.selectedURLs) }
                .keyboardShortcut("c", modifiers: [.control, .command])
                .disabled(app.selectedURLs.isEmpty)
            Button("New Bundle from Selection…") { app.createBundleFromSelection() }
                .disabled(app.selectedURLs.isEmpty)
            Menu("Add Selection to Bundle") {
                ForEach(app.bundles, id: \.id) { bundle in
                    Button(bundle.name) {
                        app.addPaths(app.selectedURLs.map(\.path), to: bundle)
                    }
                }
            }
            .disabled(app.bundles.isEmpty || app.selectedURLs.isEmpty)
            Divider()
            Picker("Format", selection: Binding(
                get: { app.contextFormat },
                set: { app.contextFormat = $0 }
            )) {
                ForEach(ContextFormat.allCases, id: \.self) { fmt in
                    Text(fmt.label).tag(fmt)
                }
            }
        }

        // View
        CommandGroup(after: .toolbar) {
            Toggle("Document Tag Header", isOn: Bindable(app).showEditorTags)
                .keyboardShortcut("t", modifiers: [.shift, .command])
            Toggle("Structured Config Editor", isOn: Bindable(app).configStructuredByDefault)
            Divider()
            Toggle("Show Hidden Files", isOn: Bindable(app).showBrowserHidden)
                .keyboardShortcut(".", modifiers: [.shift, .command])
            Toggle("Show Hidden Pins", isOn: Bindable(app).showPinnedHidden)
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
