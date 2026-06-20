import SwiftUI

/// Severity/status colors for Config Radar. Scoped to these views — do not
/// reuse elsewhere. Values match the codebase's `Color(red:green:blue:)` style.
enum ConfigRadarPalette {
    /// Reserved for secret exposure (future leak detection). Loud.
    static let leak      = Color(red: 0.90, green: 0.28, blue: 0.30)
    /// Copies disagree.
    static let drift     = Color(red: 0.91, green: 0.64, blue: 0.24)
    /// Absent / nothing to compare. Quiet on purpose.
    static let gap       = Color(red: 0.43, green: 0.46, blue: 0.53)
    /// In sync / canonical / primary actions.
    static let canonical = Color(red: 0.37, green: 0.78, blue: 0.76)
    /// Diff add / remove inside the drift band.
    static let added     = Color(red: 0.25, green: 0.73, blue: 0.31)
    static let removed   = Color(red: 0.90, green: 0.28, blue: 0.30)
}
