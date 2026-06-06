import SwiftUI
import AppKit

@main
struct LumeApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .frame(minWidth: 720, minHeight: 440)
                .task { app.restoreLastFolder() }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save") { app.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!app.isDirty)
            }
            CommandGroup(after: .newItem) {
                Button("Open Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { app.openFolder(url) }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
