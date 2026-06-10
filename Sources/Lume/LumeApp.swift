import SwiftUI
import AppKit
import SwiftData
import LumeKit

@main
struct LumeApp: App {
    @State private var app = AppState()
    private let container: ModelContainer
    /// How store setup went; surfaced as a banner after launch folder restore
    /// (restore calls `openFolder`, which clears notices).
    private let storeHealth: StoreHealth

    init() {
        let result = LibraryContainerFactory.make()
        container = result.container
        storeHealth = result.health
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .modelContainer(container)
                .frame(minWidth: 720, minHeight: 440)
                .task {
                    // AppState is shared across windows: only the FIRST window may
                    // run launch setup, or ⌘N would re-attach the library and
                    // re-restore the last folder, nuking the existing window's
                    // navigation/selection state.
                    guard app.library == nil else { return }
                    app.attach(library: LibraryStore(context: container.mainContext))
                    if !app.applyLaunchEnvironment() { app.restoreLastFolder() }
                    app.surfaceStoreHealth(storeHealth)
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands { LumeCommands(app: app) }
    }
}
