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

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 460)
        }
        .modelContainer(Self.sharedContainer)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 760)
        .commands {
            // ⌘O — always available to open a folder in Browse.
            CommandGroup(after: .newItem) {
                Button("Open Folder…") {
                    post(.lumeOpenFolder)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Open / Drill In") {
                    post(.lumeOpenOrDrill)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Go Up") {
                    post(.lumeDrillUp)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Find in Sidebar") {
                    post(.lumeFocusFilter)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Rename") {
                    post(.lumeRename)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Pin / Unpin") {
                    post(.lumePin)
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
