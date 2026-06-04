import SwiftUI
import SwiftData
import AppKit
import LumeCore

extension Notification.Name {
    static let lumeOpenFolder  = Notification.Name("lumeOpenFolder")
    static let lumeRename      = Notification.Name("lumeRename")
    static let lumePin         = Notification.Name("lumePin")
    static let lumeDrillUp     = Notification.Name("lumeDrillUp")
    static let lumeOpenOrDrill = Notification.Name("lumeOpenOrDrill")
    static let lumeFocusFilter = Notification.Name("lumeFocusFilter")
}

/// Forces the SPM executable to behave like a regular foreground GUI app.
/// A bare `.executable` target launches as an accessory/background process,
/// so the window can fail to appear without an explicit activation policy.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Use the bundled Lume icon for the Dock/⌘-Tab even when run as a bare
        // SPM executable (no Info.plist). A real .app bundle also sets it via
        // CFBundleIconFile, but this covers `swift run` too.
        if let url = Bundle.module.url(forResource: "Lume", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        // Persist window size/position across launches (friendly native behavior).
        DispatchQueue.main.async {
            NSApp.windows.first?.setFrameAutosaveName("LumeMainWindow")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// A SwiftData store at an explicit, stable on-disk path. A bare SPM
    /// executable has no bundle identifier, so the DEFAULT store location is
    /// not reliable across launches — pinning it here makes favorites, tags,
    /// notes, and bookmarks PERPETUAL.
    private static let sharedContainer: ModelContainer = {
        let schema = Schema([Favorite.self, Tag.self, FileMeta.self, Bookmark.self])
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: support.appendingPathComponent("Lume.store"))
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create Lume store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 460)
        }
        .modelContainer(Self.sharedContainer)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 760)
        .commands { LumeCommands() }
    }
}
