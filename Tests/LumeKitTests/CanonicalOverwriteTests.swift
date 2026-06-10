import Testing
import Foundation
@testable import LumeKit

struct CanonicalOverwriteTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-overwrite-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func tempBinaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-overwrite-\(UUID().uuidString).bin")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)   // invalid UTF-8
        return url
    }

    @Test func overwritesTargetsAndCapturesRestores() throws {
        let canonical = try tempFile("canon")
        let target = try tempFile("old")
        defer {
            try? FileManager.default.removeItem(at: canonical)
            try? FileManager.default.removeItem(at: target)
        }
        let outcome = try #require(CanonicalOverwrite.run(targets: [target], canonical: canonical))
        #expect(try String(contentsOf: target, encoding: .utf8) == "canon")
        #expect(outcome.restores == [CanonicalOverwrite.Restore(url: target, text: "old")])
        #expect(outcome.skipped.isEmpty)
    }

    @Test func neverWritesTheCanonicalItself() throws {
        let canonical = try tempFile("canon")
        defer { try? FileManager.default.removeItem(at: canonical) }
        let outcome = try #require(CanonicalOverwrite.run(targets: [canonical], canonical: canonical))
        #expect(outcome.restores.isEmpty)
        #expect(outcome.skipped.isEmpty)
    }

    @Test func skipsNonUTF8TargetsUntouched() throws {
        let canonical = try tempFile("canon")
        let binary = try tempBinaryFile()
        defer {
            try? FileManager.default.removeItem(at: canonical)
            try? FileManager.default.removeItem(at: binary)
        }
        let outcome = try #require(CanonicalOverwrite.run(targets: [binary], canonical: canonical))
        #expect(outcome.restores.isEmpty)
        #expect(outcome.skipped == [binary.lastPathComponent])
        #expect(try Data(contentsOf: binary) == Data([0xFF, 0xFE, 0x00, 0x80]))
    }

    @Test func unreadableCanonicalReturnsNilAndWritesNothing() throws {
        let missing = URL(fileURLWithPath: "/nope/missing-\(UUID().uuidString).txt")
        let target = try tempFile("old")
        defer { try? FileManager.default.removeItem(at: target) }
        #expect(CanonicalOverwrite.run(targets: [target], canonical: missing) == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }
}
