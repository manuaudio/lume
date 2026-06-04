import SwiftUI

/// Exposes the focused window's `AppModel` to the menu bar `Commands`, so View
/// menu items can reflect and drive live app state (checkmarks, shortcuts).
struct AppModelFocusedKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }
}

/// The app's menu-bar commands. Stateless navigation actions post notifications
/// (handled by `ContentView`); the View menu binds directly to the focused
/// `AppModel` so its toggles show checkmarks and stay in sync.
struct LumeCommands: Commands {
    @FocusedValue(\.appModel) private var model: AppModel?

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    var body: some Commands {
        // ⌘O — always available to open a folder in Browse.
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { post(.lumeOpenFolder) }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("View") {
            if let model {
                Toggle("Document Tag Header", isOn: bind(model, \.showEditorTags))
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Toggle("Structured Config Editor", isOn: bind(model, \.configStructuredByDefault))
                Divider()
                Toggle("Show Hidden Files", isOn: bind(model, \.showBrowserHidden))
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle("Show Hidden Pins", isOn: bind(model, \.showPinnedHidden))
                Toggle("Files Only", isOn: bind(model, \.filesOnly))
            } else {
                Button("Document Tag Header") {}.disabled(true)
            }
        }

        CommandMenu("Navigate") {
            Button("Open / Drill In") { post(.lumeOpenOrDrill) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Go Up") { post(.lumeDrillUp) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Find in Sidebar") { post(.lumeFocusFilter) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Rename") { post(.lumeRename) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Pin / Unpin") { post(.lumePin) }
                .keyboardShortcut("d", modifiers: .command)
        }
    }

    /// A two-way `Binding` into one of the focused model's persisted flags.
    private func bind(_ model: AppModel, _ keyPath: ReferenceWritableKeyPath<AppModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
    }
}
