import Foundation

/// Validates a user-typed file name for same-directory operations (rename).
public enum FileNameValidator {
    /// True if `name` is usable as a single path component: non-empty, no "/"
    /// or NUL, and not a traversal component ("." / ".."). With "/" rejected, a
    /// ".." appearing inside a longer name (e.g. "notes..md") cannot traverse.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.contains("/"), !name.contains("\0") else { return false }
        guard name != ".", name != ".." else { return false }
        return true
    }
}
