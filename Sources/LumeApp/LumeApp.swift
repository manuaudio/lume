import SwiftUI
import SwiftData
import AppKit
import LumeCore

/// Forces the SPM executable to behave like a regular foreground GUI app.
/// A bare `.executable` target launches as an accessory/background process,
/// so the window can fail to appear without an explicit activation policy.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .modelContainer(for: [Favorite.self, Tag.self, FileMeta.self])
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 760)

        .commands {
            CommandGroup(replacing: .sidebar) {
                // Reserve standard sidebar toggle slot; handled by NavigationSplitView.
            }
        }
    }
}
