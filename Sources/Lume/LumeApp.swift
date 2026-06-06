import SwiftUI

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
    }
}
