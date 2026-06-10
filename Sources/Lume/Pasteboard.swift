import AppKit

/// Tiny NSPasteboard facade so every clipboard write goes through one place,
/// and secret-bearing writes are concealed consistently.
enum Pasteboard {
    /// Clipboard-manager opt-out marker (see http://nspasteboard.org): managers
    /// that honor it skip the entry, so secrets aren't persisted in clipboard
    /// history or synced via Universal Clipboard handlers.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Replace the general pasteboard contents with `text`. Pass
    /// `concealed: true` for anything that may contain a secret (env values,
    /// assembled file contents); plain for inert text like file paths.
    static func write(_ text: String, concealed: Bool = false) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            pasteboard.setString("", forType: concealedType)
        }
    }
}
