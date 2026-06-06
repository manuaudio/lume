import Testing
import Foundation
@testable import LumeKit

struct TextDocumentTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-doc-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func loadsUTF8Text() async throws {
        let url = try tempFile("hello\nworld")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try await TextDocument.load(url)
        #expect(doc.text == "hello\nworld")
        #expect(doc.url == url)
    }

    @Test func savesTextBackToDisk() async throws {
        let url = try tempFile("original")
        defer { try? FileManager.default.removeItem(at: url) }
        var doc = try await TextDocument.load(url)
        doc.text = "changed"
        try doc.save()
        let reloaded = try await TextDocument.load(url)
        #expect(reloaded.text == "changed")
    }

    @Test func loadingMissingFileThrows() async {
        let url = URL(fileURLWithPath: "/nope/does-not-exist-\(UUID().uuidString).txt")
        await #expect(throws: (any Error).self) {
            _ = try await TextDocument.load(url)
        }
    }
}
