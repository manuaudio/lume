import Testing
@testable import LumeCore

@Test func routesEachKindToExpectedViewer() {
    #expect(DocumentRouter.viewer(for: .markdown) == .markdownEditor)
    #expect(DocumentRouter.viewer(for: .env) == .envEditor)
    #expect(DocumentRouter.viewer(for: .code) == .codeViewer)
    #expect(DocumentRouter.viewer(for: .pdf) == .pdf)
    #expect(DocumentRouter.viewer(for: .previewable) == .quickLook)
    #expect(DocumentRouter.viewer(for: .html) == .html)
    #expect(DocumentRouter.viewer(for: .unsupported) == .quickLook)
}

@Test func markdownIsEditableOthersAreNotExceptEnv() {
    #expect(DocumentViewer.markdownEditor.isEditable)
    #expect(DocumentViewer.envEditor.isEditable)
    #expect(!DocumentViewer.codeViewer.isEditable)
    #expect(!DocumentViewer.pdf.isEditable)
    #expect(!DocumentViewer.quickLook.isEditable)
    #expect(!DocumentViewer.html.isEditable)
}
