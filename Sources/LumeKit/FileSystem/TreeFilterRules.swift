import Foundation

/// Name-level visibility rules shared by every tree backend (local + SSH),
/// extracted from `FileService` so remote listings filter identically.
public enum TreeFilterRules {
    /// Names that are never shown, even with "Show hidden" on — pure noise
    /// the user never curates.
    public static let ignoredNames: Set<String> = [
        ".DS_Store", "node_modules", ".git", ".build", ".svn",
    ]

    /// Whether `name` appears in the tree. `.env*` stays visible regardless
    /// of the hidden toggle (it's a curated config, not noise).
    public static func isVisible(name: String, includeHidden: Bool) -> Bool {
        if ignoredNames.contains(name) { return false }
        if !includeHidden, name.hasPrefix("."), name != ".env", !name.hasPrefix(".env.") {
            return false
        }
        return true
    }
}
