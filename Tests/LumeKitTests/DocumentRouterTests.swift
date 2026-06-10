import Testing
@testable import LumeKit

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

@Test func filenameRoutingClaimsConfigFormats() {
    // Every registered ConfigRegistry extension lands on the structured editor,
    // even though json/yaml/toml detect as `.code`.
    #expect(DocumentRouter.viewer(forFilename: "package.json") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "Info.plist") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "config.yaml") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "ci.yml") == .configEditor)
    #expect(DocumentRouter.viewer(forFilename: "Cargo.toml") == .configEditor)
}

@Test func filenameRoutingPrefersEnvOverConfig() {
    // .env* matches by NAME before extension logic — ".env.yaml" must NOT fall
    // into the YAML config editor (it's a masked secrets file).
    #expect(DocumentRouter.viewer(forFilename: ".env") == .envEditor)
    #expect(DocumentRouter.viewer(forFilename: ".env.local") == .envEditor)
    #expect(DocumentRouter.viewer(forFilename: ".env.yaml") == .envEditor)
}

@Test func filenameRoutingFallsThroughToKind() {
    #expect(DocumentRouter.viewer(forFilename: "README.md") == .markdownEditor)
    #expect(DocumentRouter.viewer(forFilename: "main.swift") == .codeViewer)
    #expect(DocumentRouter.viewer(forFilename: "report.pdf") == .pdf)
    #expect(DocumentRouter.viewer(forFilename: "photo.png") == .image)
    #expect(DocumentRouter.viewer(forFilename: "index.html") == .html)
    #expect(DocumentRouter.viewer(forFilename: "report.docx") == .quickLook)
    #expect(DocumentRouter.viewer(forFilename: "mystery.bin") == .quickLook)
}

@Test func editorsAreEditableViewersAreNot() {
    #expect(DocumentViewer.markdownEditor.isEditable)
    #expect(DocumentViewer.envEditor.isEditable)
    #expect(DocumentViewer.configEditor.isEditable)
    #expect(!DocumentViewer.codeViewer.isEditable)
    #expect(!DocumentViewer.pdf.isEditable)
    #expect(!DocumentViewer.image.isEditable)
    #expect(!DocumentViewer.quickLook.isEditable)
    #expect(!DocumentViewer.html.isEditable)
}

@Test func imageKindDetectedFromExtension() {
    #expect(FileKind.detect(filename: "photo.jpg") == .image)
    #expect(FileKind.detect(filename: "PHOTO.JPEG") == .image)
    #expect(FileKind.detect(filename: "art.png") == .image)
    #expect(FileKind.detect(filename: "scan.heic") == .image)
    // Office docs stay on QuickLook, not the image path.
    #expect(FileKind.detect(filename: "report.docx") == .previewable)
}
