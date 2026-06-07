import SwiftUI
import AppKit
import SwiftData
import LumeKit

@main
struct LumeApp: App {
    @State private var app = AppState()
    private let container: ModelContainer

    init() {
        let schema = Schema([Favorite.self, Bookmark.self, Tag.self, FileMeta.self])
        do {
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            // A corrupt store shouldn't brick the app: fall back to in-memory so
            // the editor still works (favorites/tags just won't persist).
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .modelContainer(container)
                .frame(minWidth: 720, minHeight: 440)
                .task {
                    app.attach(library: LibraryStore(context: container.mainContext))
                    if !app.applyLaunchEnvironment() { app.restoreLastFolder() }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands { LumeCommands(app: app) }
    }
}
