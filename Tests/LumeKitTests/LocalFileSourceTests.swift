import Testing
import Foundation
@testable import LumeKit

struct LocalFileSourceTests {
    /// Builds a fixture dir: visible files, a dotfile, .env, node_modules, a subdir, and a symlink.
    private func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.md"),
            withDestinationURL: dir.appendingPathComponent("alpha.md"))
        return dir
    }

    @Test func listMatchesFileServiceEnumeration() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LocalFileSource()
        let viaSource = try await source.list(dir.path, includeHidden: false)
        let viaService = try FileService().enumerate(dir, includeHidden: false)
        #expect(viaSource.map(\.name) == viaService.map(\.name))
        #expect(viaSource.map(\.isDirectory) == viaService.map(\.isDirectory))
        #expect(viaSource.map(\.isSymlink) == viaService.map(\.isSymlink))
        // Folders first, .env visible, dotfile + node_modules filtered; symlink is a leaf:
        #expect(viaSource.map(\.name) == ["sub", ".env", "alpha.md", "link.md"])
    }

    @Test func readWriteRoundtrip() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("alpha.md").path
        let source = LocalFileSource()
        try await source.write("hello remote world", to: file)
        let text = try await source.read(file)
        #expect(text == "hello remote world")
    }

    @Test func statReportsDirectoryAndSize() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LocalFileSource()
        let dirMeta = try await source.stat(dir.appendingPathComponent("sub").path)
        #expect(dirMeta.isDirectory)
        let fileMeta = try await source.stat(dir.appendingPathComponent("alpha.md").path)
        #expect(!fileMeta.isDirectory)
        #expect(fileMeta.size == 1)
        #expect(fileMeta.mode != nil)
    }
}
