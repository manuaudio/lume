import Testing
import FileSystemKit
@testable import DocumentKit

@Test func routesEachKindToExpectedViewer() {
    #expect(DocumentRouter.viewer(for: .markdown) == .markdownEditor)
    #expect(DocumentRouter.viewer(for: .env) == .envEditor)
    #expect(DocumentRouter.viewer(for: .code) == .codeViewer)
    #expect(DocumentRouter.viewer(for: .pdf) == .pdf)
    #expect(DocumentRouter.viewer(for: .image) == .image)
    #expect(DocumentRouter.viewer(for: .previewable) == .quickLook)
    #expect(DocumentRouter.viewer(for: .html) == .html)
    #expect(DocumentRouter.viewer(for: .unsupported) == .quickLook)
}

@Test func imageKindDetectedFromExtension() {
    #expect(FileKind.detect(filename: "photo.jpg") == .image)
    #expect(FileKind.detect(filename: "PHOTO.JPEG") == .image)
    #expect(FileKind.detect(filename: "art.png") == .image)
    #expect(FileKind.detect(filename: "scan.heic") == .image)
    // Office docs stay on QuickLook, not the image path.
    #expect(FileKind.detect(filename: "report.docx") == .previewable)
}

@Test func markdownIsEditableOthersAreNotExceptEnv() {
    #expect(DocumentViewer.markdownEditor.isEditable)
    #expect(DocumentViewer.envEditor.isEditable)
    #expect(!DocumentViewer.codeViewer.isEditable)
    #expect(!DocumentViewer.pdf.isEditable)
    #expect(!DocumentViewer.image.isEditable)
    #expect(!DocumentViewer.quickLook.isEditable)
    #expect(!DocumentViewer.html.isEditable)
}
