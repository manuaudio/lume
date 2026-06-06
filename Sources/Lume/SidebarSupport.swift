import SwiftUI
import LumeKit

/// SF Symbol for a file kind (folders are handled by the caller).
func symbolName(for kind: FileKind) -> String {
    switch kind {
    case .markdown:    return "doc.richtext"
    case .env:         return "key.fill"
    case .pdf:         return "doc.text.fill"
    case .image:       return "photo"
    case .html:        return "globe"
    case .code:        return "chevron.left.forwardslash.chevron.right"
    case .previewable: return "doc.fill"
    case .unsupported: return "doc"
    }
}

extension Color {
    /// Bridge a UI-free `TagPalette.Swatch` into a SwiftUI `Color`.
    init(_ swatch: TagPalette.Swatch) {
        self.init(red: swatch.red, green: swatch.green, blue: swatch.blue)
    }

    /// The color for a stored tag color index.
    static func tag(_ colorIndex: Int) -> Color {
        Color(TagPalette.swatch(at: colorIndex))
    }
}
