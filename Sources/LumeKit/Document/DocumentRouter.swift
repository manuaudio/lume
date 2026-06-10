import Foundation

/// The concrete surface used to display a document.
public enum DocumentViewer: Equatable, Sendable {
    case markdownEditor   // styled-source text editor (editable)
    case envEditor        // native masked key=value editor (editable)
    case configEditor     // structured config editor — JSON/plist/YAML/TOML (editable)
    case codeViewer       // read-only syntax-highlighted source
    case pdf              // paginated PDF document viewer
    case image            // native, layer-backed image viewer (GPU-composited)
    case quickLook        // system preview (docx/office/unsupported long-tail)
    case html             // rendered web content

    public var isEditable: Bool {
        switch self {
        case .markdownEditor, .envEditor, .configEditor: return true
        case .codeViewer, .pdf, .image, .quickLook, .html: return false
        }
    }
}

public enum DocumentRouter {
    /// Route by kind alone. Prefer `viewer(forFilename:)`, which also claims
    /// structured config files; this overload can't see them (config formats
    /// are matched by extension, several of which detect as `.code`).
    public static func viewer(for kind: FileKind) -> DocumentViewer {
        switch kind {
        case .markdown: return .markdownEditor
        case .env: return .envEditor
        case .code: return .codeViewer
        case .pdf: return .pdf
        case .image: return .image
        case .previewable: return .quickLook
        case .html: return .html
        case .unsupported: return .quickLook
        }
    }

    /// Single source of truth for the detail pane. Precedence:
    ///   1. `.env` / `.env.*` (matched by NAME — ".env.yaml" is env, not YAML),
    ///   2. any `ConfigRegistry` format claiming the extension → `configEditor`,
    ///   3. plain kind routing.
    public static func viewer(forFilename name: String) -> DocumentViewer {
        let kind = FileKind.detect(filename: name)
        if kind == .env { return .envEditor }
        if ConfigRegistry.format(forFilename: name) != nil { return .configEditor }
        return viewer(for: kind)
    }
}
