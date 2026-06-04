import Testing
@testable import LumeCore

@Test func detectsMarkdown() {
    #expect(FileKind.detect(filename: "README.md") == .markdown)
    #expect(FileKind.detect(filename: "notes.markdown") == .markdown)
}

@Test func detectsEnvIncludingVariants() {
    #expect(FileKind.detect(filename: ".env") == .env)
    #expect(FileKind.detect(filename: ".env.local") == .env)
    #expect(FileKind.detect(filename: ".env.production") == .env)
}

@Test func detectsPdf() {
    #expect(FileKind.detect(filename: "INV-2026-0001.pdf") == .pdf)
}

@Test func detectsPreviewable() {
    #expect(FileKind.detect(filename: "invoice.docx") == .previewable)
    #expect(FileKind.detect(filename: "deck.pptx") == .previewable)
}

@Test func detectsImage() {
    // Images route to the native ImageViewer, NOT QuickLook (which aborts on
    // a pre-window previewItem assignment).
    #expect(FileKind.detect(filename: "photo.PNG") == .image)
    #expect(FileKind.detect(filename: "shot.jpeg") == .image)
    #expect(FileKind.detect(filename: "anim.gif") == .image)
    #expect(FileKind.detect(filename: "scan.HEIC") == .image)
}

@Test func detectsHtml() {
    #expect(FileKind.detect(filename: "resume.html") == .html)
}

@Test func detectsCode() {
    for name in ["build.mjs", "main.ts", "script.py", "data.json", "config.yml", "run.sh", "rows.csv", "notes.txt"] {
        #expect(FileKind.detect(filename: name) == .code, "expected .code for \(name)")
    }
}

@Test func detectsUnsupported() {
    #expect(FileKind.detect(filename: "archive.zip") == .unsupported)
    #expect(FileKind.detect(filename: "noextension") == .unsupported)
}
