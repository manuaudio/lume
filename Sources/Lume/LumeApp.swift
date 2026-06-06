import SwiftUI

@main
struct LumeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
    }
}
