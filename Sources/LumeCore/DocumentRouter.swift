/// The concrete surface used to display a document.
public enum DocumentViewer: Equatable, Sendable {
    case markdownEditor   // CodeMirror styled-source (editable)
    case envEditor        // native masked key=value (editable)
    case codeViewer       // CodeMirror read-only highlight
    case pdf              // PDFKit
    case image            // native, layer-backed NSImageView (GPU-composited)
    case quickLook        // QLPreviewView (docx/office/unsupported long-tail)
    case html             // plain WKWebView

    public var isEditable: Bool {
        switch self {
        case .markdownEditor, .envEditor: return true
        case .codeViewer, .pdf, .image, .quickLook, .html: return false
        }
    }
}

public enum DocumentRouter {
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
}
