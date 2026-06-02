import Foundation

/// What kind of document a file is — drives which viewer the app uses.
public enum FileKind: Equatable, Sendable {
    case markdown      // edit in CodeMirror styled-source
    case env           // native masked key=value view
    case pdf           // PDFKit
    case previewable   // docx / office / images via QuickLook
    case html          // plain WKWebView
    case code          // read-only CodeMirror highlight
    case unsupported   // QuickLook fallback / open in Finder

    private static let previewableExts: Set<String> = [
        "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "pages", "key", "numbers", "rtf", "rtfd",
        "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp",
    ]
    private static let codeExts: Set<String> = [
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "json", "yml", "yaml",
        "sh", "bash", "zsh", "csv", "txt", "swift", "rb", "go", "rs",
        "toml", "xml", "css", "scss",
    ]

    /// Detect a file's kind from its name (case-insensitive extension).
    public static func detect(filename: String) -> FileKind {
        // .env and .env.* are matched by name prefix, before extension logic,
        // because ".env.local".pathExtension == "local".
        if filename == ".env" || filename.hasPrefix(".env.") {
            return .env
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return .markdown
        case "pdf": return .pdf
        case "html", "htm": return .html
        case let e where previewableExts.contains(e): return .previewable
        case let e where codeExts.contains(e): return .code
        default: return .unsupported
        }
    }
}
